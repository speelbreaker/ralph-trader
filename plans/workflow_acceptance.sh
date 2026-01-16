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
require_tools git jq python3 mktemp find wc tr sed awk stat sort head tail date grep
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

count_blocked() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_*' | wc -l | tr -d ' '
}

count_blocked_incomplete() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_incomplete_*' | wc -l | tr -d ' '
}

blocked_dirs_all() {
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_*' -print 2>/dev/null | sort -u
}

snapshot_blocked_dirs() {
  blocked_dirs_all
}

diff_blocked_dirs() {
  local before="$1"
  local after="$2"
  comm -13 <(printf '%s\n' "$before" | sed '/^$/d' | sort -u) <(printf '%s\n' "$after" | sed '/^$/d' | sort -u)
}

assert_new_blocked() {
  local before="$1"
  local after
  local new_dirs
  after="$(snapshot_blocked_dirs)"
  new_dirs="$(diff_blocked_dirs "$before" "$after")"
  if [[ -z "$new_dirs" ]]; then
    echo "FAIL: expected new blocked artifact" >&2
    return 1
  fi
  printf '%s\n' "$new_dirs"
}

assert_new_blocked_with_reason() {
  local before="$1"
  local reason="$2"
  local new_dirs
  new_dirs="$(assert_new_blocked "$before")" || return 1
  if [[ -z "$new_dirs" ]]; then
    echo "FAIL: expected new blocked artifact for ${reason}" >&2
    return 1
  fi
  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if [[ -f "$dir/blocked_item.json" ]]; then
      if [[ "$(run_in_worktree jq -r '.reason' "$dir/blocked_item.json" 2>/dev/null || true)" == "$reason" ]]; then
        echo "$dir"
        return 0
      fi
    fi
  done <<< "$new_dirs"
  echo "FAIL: expected blocked artifact reason=${reason}" >&2
  return 1
}

RUN_ID_COUNTER=0
next_run_id() {
  RUN_ID_COUNTER=$((RUN_ID_COUNTER + 1))
  echo "acceptance-run-${RUN_ID_COUNTER}"
}

assert_manifest_valid() {
  local manifest="$1"
  if ! run_in_worktree ./plans/artifacts_validate.sh "$manifest" >/dev/null 2>&1; then
    echo "FAIL: expected artifact manifest to validate: $manifest" >&2
    return 1
  fi
}

assert_manifest_run_id() {
  local manifest="$1"
  local expected="$2"
  local actual
  actual="$(run_in_worktree jq -r '.run_id // empty' "$manifest" 2>/dev/null || true)"
  if [[ -z "$actual" ]]; then
    echo "FAIL: expected run_id in manifest" >&2
    return 1
  fi
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "FAIL: expected manifest run_id=${expected}, got ${actual}" >&2
    return 1
  fi
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
  rm -rf "$WORKTREE/.ralph/blocked_"* "$WORKTREE/.ralph/blocked_incomplete_"* 2>/dev/null || true
}

STUB_DIR="$WORKTREE/.ralph/stubs"
mkdir -p "$STUB_DIR"

snapshot_worktree_if_dirty() {
  run_in_worktree bash -c '
    if [[ -n "$(git status --porcelain)" ]]; then
      git add -A
      if ! git diff --cached --quiet; then
        git -c user.name="workflow-acceptance" -c user.email="workflow@local" \
          commit -m "workflow_acceptance snapshot" >/dev/null 2>&1
      fi
    fi
  '
}

run_ralph() {
  snapshot_worktree_if_dirty
  run_in_worktree "$@"
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

add_optional_overlays() {
  local overlay
  for overlay in "$@"; do
    if [[ -f "$ROOT/$overlay" ]]; then
      OVERLAY_FILES+=("$overlay")
    else
      MISSING_OVERLAY_FILES+=("$overlay")
    fi
  done
}

# Ensure tests run against the working tree versions while keeping the worktree clean.
OVERLAY_FILES=(
  "plans/ralph.sh"
  "plans/verify.sh"
  "plans/update_task.sh"
  "plans/prd.json"
  "plans/prd_schema_check.sh"
  "plans/prd_lint.sh"
  "plans/prd_pipeline.sh"
  "plans/prd_autofix.sh"
  "plans/run_prd_auditor.sh"
  "plans/build_markdown_digest.sh"
  "plans/build_contract_digest.sh"
  "plans/build_plan_digest.sh"
  "plans/prd_slice_prepare.sh"
  "plans/contract_check.sh"
  "plans/contract_coverage_matrix.py"
  "plans/contract_coverage_promote.sh"
  "plans/artifacts_validate.sh"
  "plans/contract_review_validate.sh"
  "plans/workflow_contract_gate.sh"
  "plans/workflow_contract_map.json"
  "specs/WORKFLOW_CONTRACT.md"
  "CONTRACT.md"
  "IMPLEMENTATION_PLAN.md"
  "docs/contract_anchors.md"
  "docs/validation_rules.md"
  "docs/contract_kernel.json"
  "scripts/build_contract_kernel.py"
  "scripts/check_contract_kernel.py"
  "scripts/contract_kernel_lib.py"
  "scripts/test_contract_kernel.py"
  "docs/schemas/artifacts.schema.json"
)
OPTIONAL_OVERLAY_FILES=(
  "plans/prd_ref_check.sh"
  "plans/prd_ref_index.sh"
)
MISSING_OVERLAY_FILES=()
add_optional_overlays "${OPTIONAL_OVERLAY_FILES[@]}"

echo "Test 0e: optional overlay files are skipped when missing"
if (( ${#MISSING_OVERLAY_FILES[@]} > 0 )); then
  for overlay in "${MISSING_OVERLAY_FILES[@]}"; do
    if printf '%s\n' "${OVERLAY_FILES[@]}" | grep -Fxq "$overlay"; then
      echo "FAIL: optional overlay listed despite missing: $overlay" >&2
      exit 1
    fi
  done
fi

run_in_worktree git update-index --no-skip-worktree "${OVERLAY_FILES[@]}" >/dev/null 2>&1 || true
for overlay in "${OVERLAY_FILES[@]}"; do
  copy_worktree_file "$overlay"
done
scripts_to_chmod=(
  "ralph.sh"
  "verify.sh"
  "update_task.sh"
  "prd_schema_check.sh"
  "prd_lint.sh"
  "prd_pipeline.sh"
  "prd_autofix.sh"
  "run_prd_auditor.sh"
  "build_markdown_digest.sh"
  "build_contract_digest.sh"
  "build_plan_digest.sh"
  "prd_slice_prepare.sh"
  "contract_check.sh"
  "contract_coverage_matrix.py"
  "contract_coverage_promote.sh"
  "artifacts_validate.sh"
  "contract_review_validate.sh"
  "workflow_contract_gate.sh"
  "prd_ref_check.sh"
  "prd_ref_index.sh"
)
for script in "${scripts_to_chmod[@]}"; do
  if [[ -f "$WORKTREE/plans/$script" ]]; then
    chmod +x "$WORKTREE/plans/$script" >/dev/null 2>&1 || true
  fi
done
run_in_worktree git update-index --skip-worktree "${OVERLAY_FILES[@]}" >/dev/null 2>&1 || true

echo "Test 0f: prd_pipeline logs skipped ref check"
run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/prd_pipeline_skip"
  mkdir -p "$tmpdir"
  prd="$tmpdir/prd.json"
  cat > "$prd" <<'"'"'JSON'"'"'
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
      "id": "S1-030",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "PRD pipeline skip ref check test",
      "contract_refs": ["CONTRACT.md §1"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": {
        "touch": ["plans/verify.sh"],
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
  progress="$tmpdir/progress.txt"
  PRD_FILE="$prd" PROGRESS_FILE="$progress" PRD_CUTTER_CMD="/bin/true" PRD_AUDITOR_ENABLED=0 PRD_REF_CHECK_ENABLED=0 ./plans/prd_pipeline.sh >/dev/null 2>&1
  if ! grep -q "PRD ref check skipped" "$progress"; then
    echo "FAIL: expected progress log to note skipped prd_ref_check" >&2
    exit 1
  fi
'

echo "Test 0g: manifest written on preflight block"
run_id="$(next_run_id)"
run_in_worktree bash -c '
  set -euo pipefail
  cat > .ralph/artifacts.json <<'"'"'JSON'"'"'
{
  "schema_version": 1,
  "run_id": "stale",
  "iter_dir": null,
  "head_before": null,
  "head_after": null,
  "commit_count": null,
  "verify_pre_log_path": null,
  "verify_post_log_path": null,
  "final_verify_log_path": null,
  "final_verify_status": "PASS",
  "contract_review_path": null,
  "contract_check_report_path": null,
  "blocked_dir": null,
  "blocked_reason": null,
  "blocked_details": null,
  "skipped_checks": [],
  "generated_at": "2026-01-15T00:00:00Z"
}
JSON
'
set +e
run_in_worktree env \
  PRD_FILE=".ralph/missing_prd.json" \
  VERIFY_SH="/bin/true" \
  RPH_AGENT_CMD="true" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_RUN_ID="$run_id" \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for preflight block" >&2
  exit 1
fi
manifest=".ralph/artifacts.json"
if ! run_in_worktree test -f "$manifest"; then
  echo "FAIL: expected manifest for preflight block" >&2
  exit 1
fi
if ! assert_manifest_valid "$manifest"; then
  exit 1
fi
if ! assert_manifest_run_id "$manifest" "$run_id"; then
  exit 1
fi
status="$(run_in_worktree jq -r ".final_verify_status" "$manifest")"
if [[ "$status" != "BLOCKED" ]]; then
  echo "FAIL: expected manifest final_verify_status=BLOCKED on preflight block" >&2
  exit 1
fi
blocked_reason="$(run_in_worktree jq -r ".blocked_reason" "$manifest")"
if [[ "$blocked_reason" != "missing_prd" ]]; then
  echo "FAIL: expected blocked_reason=missing_prd" >&2
  exit 1
fi
if ! run_in_worktree jq -e ".skipped_checks[]? | select(.name==\"final_verify\" and .reason==\"preflight_blocked\")" "$manifest" >/dev/null 2>&1; then
  echo "FAIL: expected final_verify preflight_blocked in skipped_checks" >&2
  exit 1
fi

run_in_worktree ./plans/prd_schema_check.sh "plans/prd.json" >/dev/null 2>&1
run_in_worktree ./plans/prd_lint.sh "plans/prd.json" >/dev/null 2>&1
if run_in_worktree test -x "./plans/prd_ref_check.sh"; then
  run_in_worktree ./plans/prd_ref_check.sh "plans/prd.json" >/dev/null 2>&1
else
  echo "WARN: prd_ref_check.sh missing; skipping ref check"
fi
run_in_worktree mkdir -p ".ralph"
cp "$ROOT/plans/story_verify_allowlist.txt" "$WORKTREE/.ralph/story_verify_allowlist.txt"
export RPH_STORY_VERIFY_ALLOWLIST_FILE="$WORKTREE/.ralph/story_verify_allowlist.txt"
if ! run_in_worktree bash -c '
  allowlist="${RPH_STORY_VERIFY_ALLOWLIST_FILE:-plans/story_verify_allowlist.txt}"
  if [[ ! -f "$allowlist" ]]; then
    echo "FAIL: story verify allowlist missing: $allowlist" >&2
    exit 1
  fi
  missing=0
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if ! grep -Fxq "$cmd" "$allowlist"; then
      echo "FAIL: story verify command not allowlisted: $cmd" >&2
      missing=1
    fi
  done < <(jq -r ".items[].verify[] | select(. != \"./plans/verify.sh\")" plans/prd.json)
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
'; then
  exit 1
fi

if ! run_in_worktree bash -c '
  last=-1
  while IFS= read -r slice; do
    if [[ "$slice" -lt "$last" ]]; then
      echo "FAIL: PRD slices out of order (found $slice after $last)" >&2
      exit 1
    fi
    last="$slice"
  done < <(jq -r ".items[].slice" plans/prd.json)
'; then
  exit 1
fi

if ! run_in_worktree bash -c '
  set -euo pipefail
  bad="$(jq -r '"'"'
    .items as $items
    | ($items | map({key:.id, value:.passes}) | from_entries) as $pass
    | ($items | map({key:.id, value:true}) | from_entries) as $exists
    | $items[]
    | select(.passes == true)
    | .id as $item_id
    | (.dependencies // [])[]
    | . as $dep
    | if ($exists[$dep] != true) then "\($item_id) -> \($dep) (missing)"
      elif ($pass[$dep] != true) then "\($item_id) -> \($dep)"
      else empty end
  '"'"' plans/prd.json)"
  if [[ -n "$bad" ]]; then
    echo "FAIL: passes=true item depends on missing or non-passing dependency:" >&2
    echo "$bad" >&2
    exit 1
  fi
'; then
  exit 1
fi

if ! run_in_worktree test -x "plans/run_prd_auditor.sh"; then
  echo "FAIL: plans/run_prd_auditor.sh not executable" >&2
  exit 1
fi

if ! run_in_worktree test -x "plans/prd_autofix.sh"; then
  echo "FAIL: plans/prd_autofix.sh not executable" >&2
  exit 1
fi

if ! run_in_worktree test -x "plans/contract_coverage_matrix.py"; then
  echo "FAIL: plans/contract_coverage_matrix.py not executable" >&2
  exit 1
fi

if ! run_in_worktree test -x "plans/contract_coverage_promote.sh"; then
  echo "FAIL: plans/contract_coverage_promote.sh not executable" >&2
  exit 1
fi

if ! run_in_worktree awk '
  /Stage A/ {in_stage=1}
  in_stage && /Stage B/ {exit}
  in_stage && /prd_lint.sh/ && lint==0 {lint=NR}
  in_stage && /run_cmd PRD_CUTTER/ && cutter==0 {cutter=NR}
  END {
    if (lint==0 || cutter==0) exit 1
    if (lint > cutter) exit 1
  }
' "plans/prd_pipeline.sh"; then
  echo "FAIL: prd_pipeline Stage A must run lint before PRD_CUTTER" >&2
  exit 1
fi

if ! run_in_worktree awk '/PRD_AUTOFIX/ {found=1} END {exit found?0:1}' "plans/prd_pipeline.sh"; then
  echo "FAIL: prd_pipeline must support PRD_AUTOFIX in Stage A" >&2
  exit 1
fi

if ! run_in_worktree awk '/NO_PROGRESS/ {found=1} END {exit found?0:1}' "plans/prd_pipeline.sh"; then
  echo "FAIL: prd_pipeline must block on no-progress cutter runs" >&2
  exit 1
fi

contract_norm_pattern=$'sed \'s/[*`_]/'
if ! run_in_worktree grep -Fq "$contract_norm_pattern" "plans/contract_check.sh"; then
 
  echo "FAIL: contract_check must normalize markdown markers in contract text" >&2
  exit 1
fi

if ! run_in_worktree grep -q "bash -n plans/workflow_acceptance.sh" "plans/verify.sh"; then
  echo "FAIL: verify must syntax-check workflow_acceptance.sh" >&2
  exit 1
fi

if ! run_in_worktree grep -q "PATH_CONVENTION" "plans/prd_lint.sh"; then
  echo "FAIL: prd_lint must flag path convention drift" >&2
  exit 1
fi

if ! run_in_worktree grep -q "contract_coverage_matrix.py" "plans/verify.sh"; then
  echo "FAIL: verify must run contract coverage matrix" >&2
  exit 1
fi

if ! run_in_worktree grep -q "contract_coverage_ci_strict" "plans/verify.sh"; then
  echo "FAIL: verify must gate CI strict coverage via sentinel file" >&2
  exit 1
fi

if ! run_in_worktree grep -q "CONTRACT_COVERAGE_OUT" "plans/verify.sh"; then
  echo "FAIL: verify must direct contract coverage output via CONTRACT_COVERAGE_OUT" >&2
  exit 1
fi

if ! run_in_worktree grep -q "CONTRACT_COVERAGE_UPDATE_DOCS" "plans/verify.sh"; then
  echo "FAIL: verify must support CONTRACT_COVERAGE_UPDATE_DOCS override" >&2
  exit 1
fi

if ! run_in_worktree awk '/CONTRACT_COVERAGE_UPDATE_DOCS/ && /:-0/ {found=1} END {exit found?0:1}' "plans/verify.sh"; then
  echo "FAIL: verify must default CONTRACT_COVERAGE_UPDATE_DOCS to 0" >&2
  exit 1
fi

if ! run_in_worktree grep -q 'contract_coverage_out="${VERIFY_ARTIFACTS_DIR}/contract_coverage.md"' "plans/verify.sh"; then
  echo "FAIL: verify must default contract coverage output under VERIFY_ARTIFACTS_DIR" >&2
  exit 1
fi

if ! run_in_worktree test -f "scripts/contract_kernel_lib.py"; then
  echo "FAIL: expected scripts/contract_kernel_lib.py in overlay" >&2
  exit 1
fi

if ! run_in_worktree test -f "scripts/test_contract_kernel.py"; then
  echo "FAIL: expected scripts/test_contract_kernel.py in overlay" >&2
  exit 1
fi

if ! run_in_worktree grep -q "contract_kernel_tests" "plans/verify.sh"; then
  echo "FAIL: verify must run contract kernel unit tests" >&2
  exit 1
fi

if ! run_in_worktree grep -q "scripts/test_contract_kernel.py" "plans/verify.sh"; then
  echo "FAIL: verify must reference scripts/test_contract_kernel.py" >&2
  exit 1
fi

if ! run_in_worktree grep -q "WORKFLOW_ACCEPTANCE_POLICY" "plans/verify.sh"; then
  echo "FAIL: verify must support WORKFLOW_ACCEPTANCE_POLICY override" >&2
  exit 1
fi

if ! run_in_worktree grep -q "should_run_workflow_acceptance" "plans/verify.sh"; then
  echo "FAIL: verify must include workflow acceptance diff gate" >&2
  exit 1
fi

if ! run_in_worktree grep -q "is_workflow_file" "plans/verify.sh"; then
  echo "FAIL: verify must include workflow allowlist helper" >&2
  exit 1
fi

if ! run_in_worktree grep -q "collect_changed_files" "plans/verify.sh"; then
  echo "FAIL: verify must include workflow diff collector" >&2
  exit 1
fi

if ! run_in_worktree grep -q 'git diff --name-only "$BASE_REF"...HEAD' "plans/verify.sh"; then
  echo "FAIL: verify must diff against BASE_REF for workflow acceptance gate" >&2
  exit 1
fi

if ! run_in_worktree grep -q "Skipping workflow acceptance (no workflow-critical files changed; local auto mode)." "plans/verify.sh"; then
  echo "FAIL: verify must log workflow acceptance skip reason" >&2
  exit 1
fi

if ! run_in_worktree awk '
  /is_workflow_file/ {in_block=1}
  in_block && index($0, "plans/verify.sh") {has_verify=1}
  in_block && index($0, "plans/workflow_acceptance.sh") {has_accept=1}
  in_block && index($0, "specs/WORKFLOW_CONTRACT.md") {has_contract=1}
  in_block && index($0, "scripts/check_contract_kernel.py") {has_kernel=1}
  in_block && index($0, "docs/validation_rules.md") {has_rules=1}
  END { exit (has_verify && has_accept && has_contract && has_kernel && has_rules) ? 0 : 1 }
' "plans/verify.sh"; then
  echo "FAIL: workflow allowlist must include core workflow files" >&2
  exit 1
fi

if ! run_in_worktree awk 'index($0, "prompts/auditor.md") { found=1 } END { exit found?0:1 }' "plans/run_prd_auditor.sh"; then
  echo "FAIL: plans/run_prd_auditor.sh must reference prompts/auditor.md" >&2
  exit 1
fi

if ! run_in_worktree awk 'index($0, "prd_sha256") { found=1 } END { exit found?0:1 }' "plans/run_prd_auditor.sh"; then
  echo "FAIL: plans/run_prd_auditor.sh must validate prd_sha256" >&2
  exit 1
fi

if ! grep -q "Summary:" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require Summary in progress entries" >&2
  exit 1
fi
if ! grep -q "Story:" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must include Story label in progress template" >&2
  exit 1
fi
if ! grep -q "Date: YYYY-MM-DD" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must include Date template with YYYY-MM-DD" >&2
  exit 1
fi
if ! grep -q "Commands:" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require Commands in progress entries" >&2
  exit 1
fi
if ! grep -q "Evidence:" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require Evidence in progress entries" >&2
  exit 1
fi
if ! grep -q "Next:" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require Next in progress entries" >&2
  exit 1
fi
if ! grep -q "Do not paste full verify output into chat." "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must include verify output discipline guidance" >&2
  exit 1
fi
if ! grep -qi "command logs short" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must remind to keep command logs short" >&2
  exit 1
fi
if ! grep -q "Operator tip: For verification-only iterations" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must include model-split operator tip" >&2
  exit 1
fi
if ! grep -qi "Restate scope" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require scope restatement" >&2
  exit 1
fi
if ! grep -qi "acceptance tests" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require acceptance test restatement" >&2
  exit 1
fi
if ! grep -qi "verify mode" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require stating verify mode" >&2
  exit 1
fi
if ! grep -qi "small tests first" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must include small tests first instruction" >&2
  exit 1
fi
if ! grep -q "RPH_VERIFY_ONLY" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must define RPH_VERIFY_ONLY" >&2
  exit 1
fi
if ! grep -q "RPH_VERIFY_ONLY_MODEL" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must define RPH_VERIFY_ONLY_MODEL" >&2
  exit 1
fi
if ! grep -q "RPH_PROFILE_VERIFY_ONLY" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must define RPH_PROFILE_VERIFY_ONLY for verify profile" >&2
  exit 1
fi
if ! grep -q "RPH_PROFILE_MODE" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must expose RPH_PROFILE_MODE for profile behavior checks" >&2
  exit 1
fi
if ! grep -q "verify)" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must include verify profile case" >&2
  exit 1
fi
if ! grep -q "gpt-5-mini" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must mention gpt-5-mini default for verification-only model" >&2
  exit 1
fi
if ! grep -q -- "--sandbox danger-full-access" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph default agent args must include danger-full-access sandbox" >&2
  exit 1
fi
if ! grep -Eq "VERIFY_ARTIFACTS_DIR=.*\\.ralph/verify" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must default VERIFY_ARTIFACTS_DIR under .ralph/verify" >&2
  exit 1
fi
if ! grep -Fq 'mktemp -d ".ralph/${prefix}_' "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph blocked artifacts must use mktemp for unique names" >&2
  exit 1
fi

bad_scope_patterns="$(run_in_worktree jq -r '.items[].scope.touch[]?, .items[].scope.create[]? | select(endswith("/")) | select(contains("*") | not)' "$WORKTREE/plans/prd.json")"
if [[ -n "$bad_scope_patterns" ]]; then
  echo "FAIL: scope patterns ending in / must include a glob (e.g., **):" >&2
  echo "$bad_scope_patterns" >&2
  exit 1
fi

exclude_file="$(run_in_worktree git rev-parse --git-path info/exclude)"
echo ".context/" >> "$exclude_file"
echo "plans/contract_check.sh" >> "$exclude_file"
echo "plans/contract_review_validate.sh" >> "$exclude_file"
echo "plans/workflow_contract_gate.sh" >> "$exclude_file"
echo "plans/workflow_contract_map.json" >> "$exclude_file"
echo "plans/run_prd_auditor.sh" >> "$exclude_file"
echo "plans/prd_ref_check.sh" >> "$exclude_file"
echo "plans/prd_ref_index.sh" >> "$exclude_file"
echo "plans/build_markdown_digest.sh" >> "$exclude_file"
echo "plans/build_contract_digest.sh" >> "$exclude_file"
echo "plans/build_plan_digest.sh" >> "$exclude_file"
echo "plans/prd_slice_prepare.sh" >> "$exclude_file"

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

cat > "$STUB_DIR/verify_once_then_fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-quick}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
count_file="${VERIFY_COUNT_FILE:-.ralph/verify_count}"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
echo "$count" > "$count_file"
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
if [[ "$count" -ge 2 ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$STUB_DIR/verify_once_then_fail.sh"

cat > "$STUB_DIR/verify_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-quick}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
exit 0
EOF
chmod +x "$STUB_DIR/verify_pass.sh"

cat > "$STUB_DIR/verify_record_mode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
echo "VERIFY_MODE_ARG=${mode}"
exit 0
EOF
chmod +x "$STUB_DIR/verify_record_mode.sh"

cat > "$STUB_DIR/verify_fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-quick}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
exit 1
EOF
chmod +x "$STUB_DIR/verify_fail.sh"

cat > "$STUB_DIR/verify_fail_noisy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-quick}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
i=1
while [[ "$i" -le 300 ]]; do
  echo "line $i"
  i=$((i + 1))
done
echo "error: noisy failure"
echo "FAILED noisy_test"
echo "thread 'main' panicked at noisy failure"
exit 1
EOF
chmod +x "$STUB_DIR/verify_fail_noisy.sh"

cat > "$STUB_DIR/verify_pass_mode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
echo "MODE_ARG=${mode}"
exit 0
EOF
chmod +x "$STUB_DIR/verify_pass_mode.sh"
cat > "$STUB_DIR/verify_full_no_promotion.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "VERIFY_SH_SHA=stub"
echo "mode=full verify_mode=none root=/tmp"
exit 0
EOF
chmod +x "$STUB_DIR/verify_full_no_promotion.sh"

cat > "$STUB_DIR/verify_fail_on_mode.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
log_mode="$mode"
verify_mode="${VERIFY_MODE:-none}"
if [[ "$mode" == "promotion" ]]; then
  log_mode="full"
  verify_mode="promotion"
fi
echo "VERIFY_SH_SHA=stub"
echo "mode=${log_mode} verify_mode=${verify_mode} root=/tmp"
echo "MODE_ARG=${mode}"
if [[ "$mode" == "promotion" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$STUB_DIR/verify_fail_on_mode.sh"

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

cat > "$STUB_DIR/agent_mark_pass_with_commit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
progress="${PROGRESS_FILE:-plans/progress.txt}"
touch_file="${ACCEPTANCE_TOUCH_FILE:-src/lib.rs}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance mark pass with commit
Commands: echo >> ${touch_file}; git add; git commit
Evidence: acceptance stub
Next: proceed
EOT
mkdir -p "$(dirname "$touch_file")"
echo "tick $(date +%s)" >> "$touch_file"
if [[ "$progress" == .ralph/* || "$progress" == */.ralph/* ]]; then
  git add "$touch_file"
else
  git add "$touch_file" "$progress"
fi
git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: touch" >/dev/null 2>&1
echo "<mark_pass>${id}</mark_pass>"
EOF
chmod +x "$STUB_DIR/agent_mark_pass_with_commit.sh"

cat > "$STUB_DIR/agent_mark_pass_meta_only.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
progress="${PROGRESS_FILE:-plans/progress.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance mark pass meta only
Commands: append progress only
Evidence: acceptance stub
Next: proceed
EOT
git add "$progress"
git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: progress only" >/dev/null 2>&1
echo "<mark_pass>${id}</mark_pass>"
EOF
chmod +x "$STUB_DIR/agent_mark_pass_meta_only.sh"

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
if [[ "$progress" == .ralph/* || "$progress" == */.ralph/* ]]; then
  git add "$touch_file"
else
  git add "$touch_file" "$progress"
fi
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

cat > "$STUB_DIR/agent_mentions_complete.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
progress="${PROGRESS_FILE:-plans/progress.txt}"
touch_file="${ACCEPTANCE_TOUCH_FILE:-acceptance_tick.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance mention complete
Commands: none
Evidence: acceptance stub
Next: continue
EOT
mkdir -p "$(dirname "$touch_file")"
echo "tick $(date +%s)" >> "$touch_file"
git add "$touch_file" "$progress"
git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: tick" >/dev/null 2>&1
echo "If ALL items pass, output exactly: <promise>COMPLETE</promise>"
EOF
chmod +x "$STUB_DIR/agent_mentions_complete.sh"

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

cat > "$STUB_DIR/agent_modify_harness.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "# harness tamper $(date +%s)" >> plans/ralph.sh
EOF
chmod +x "$STUB_DIR/agent_modify_harness.sh"

cat > "$STUB_DIR/agent_modify_ralph_state.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .ralph
cat > .ralph/state.json <<'JSON'
{"last_verify_post_rc":0,"tampered":true}
JSON
EOF
chmod +x "$STUB_DIR/agent_modify_ralph_state.sh"

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

write_contract_check_stub_require_iter_artifacts() {
  cat > "$WORKTREE/plans/contract_check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${CONTRACT_REVIEW_OUT:-${1:-}}"
if [[ -z "$out" ]]; then
  echo "missing contract review output path" >&2
  exit 1
fi
iter_dir="$(cd "$(dirname "$out")" && pwd -P)"
selected_id="unknown"
if [[ -f "$iter_dir/selected.json" ]]; then
  selected_id="$(jq -r '.selected_id // "unknown"' "$iter_dir/selected.json" 2>/dev/null || echo "unknown")"
fi
missing=()
for f in head_before.txt head_after.txt prd_before.json prd_after.json diff.patch; do
  if [[ ! -f "$iter_dir/$f" ]]; then
    missing+=("$f")
  fi
done
decision="PASS"
confidence="high"
required_followups_json="[]"
if (( ${#missing[@]} > 0 )); then
  decision="BLOCKED"
  confidence="med"
  required_followups_json="$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)"
fi
jq -n \
  --arg selected_story_id "$selected_id" \
  --arg decision "$decision" \
  --arg confidence "$confidence" \
  --argjson required_followups "$required_followups_json" \
  '{
    selected_story_id: $selected_story_id,
    decision: $decision,
    confidence: $confidence,
    contract_refs_checked: ["CONTRACT.md §1"],
    scope_check: { changed_files: [], out_of_scope_files: [], notes: ["acceptance stub"] },
    verify_check: { verify_post_present: true, verify_post_green: true, notes: ["acceptance stub"] },
    pass_flip_check: {
      requested_mark_pass_id: $selected_story_id,
      prd_passes_before: false,
      prd_passes_after: false,
      evidence_required: [],
      evidence_found: [],
      evidence_missing: [],
      decision_on_pass_flip: "DENY"
    },
    violations: [],
    required_followups: $required_followups,
    rationale: ["acceptance stub"]
  }' > "$out"
EOF
  chmod +x "$WORKTREE/plans/contract_check.sh"
}

write_contract_check_stub "PASS"
run_in_worktree git update-index --skip-worktree plans/contract_check.sh >/dev/null 2>&1 || true

echo "Test 0a: auditor cache skip avoids agent call"
run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/audit_cache_skip"
  mkdir -p "$tmpdir"
  prd="$tmpdir/prd.json"
  audit="$tmpdir/prd_audit.json"
  cache="$tmpdir/prd_audit_cache.json"
  prompt="prompts/auditor.md"
  if [[ -f "specs/CONTRACT.md" ]]; then
    contract="specs/CONTRACT.md"
  else
    contract="CONTRACT.md"
  fi
  if [[ -f "specs/IMPLEMENTATION_PLAN.md" ]]; then
    plan="specs/IMPLEMENTATION_PLAN.md"
  else
    plan="IMPLEMENTATION_PLAN.md"
  fi
  if [[ -f "specs/WORKFLOW_CONTRACT.md" ]]; then
    workflow="specs/WORKFLOW_CONTRACT.md"
  else
    workflow="WORKFLOW_CONTRACT.md"
  fi
  hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | awk "{print \$1}"
    else
      shasum -a 256 "$1" | awk "{print \$1}"
    fi
  }
  cat > "$prd" <<JSON
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
      "id": "S1-000",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Audit cache skip test",
      "contract_refs": ["CONTRACT.md §1"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": {
        "touch": ["docs/**"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
  prd_sha="$(hash_file "$prd")"
  contract_sha="$(hash_file "$contract")"
  plan_sha="$(hash_file "$plan")"
  workflow_sha="$(hash_file "$workflow")"
  prompt_sha="$(hash_file "$prompt")"
  cat > "$audit" <<JSON
{
  "project": "StoicTrader",
  "prd_sha256": "$prd_sha",
  "inputs": {
    "prd": "$prd",
    "contract": "$contract",
    "plan": "$plan",
    "workflow_contract": "$workflow"
  },
  "summary": {
    "items_total": 1,
    "items_pass": 1,
    "items_fail": 0,
    "items_blocked": 0,
    "must_fix_count": 0
  },
  "global_findings": {
    "must_fix": [],
    "risk": [],
    "improvements": []
  },
  "items": [
    {
      "id": "S1-000",
      "slice": 1,
      "status": "PASS",
      "reasons": [],
      "schema_check": { "missing_fields": [], "notes": [] },
      "contract_check": {
        "refs_present": true,
        "refs_specific": true,
        "contract_refs_resolved": true,
        "acceptance_enforces_invariant": true,
        "contradiction": false,
        "notes": []
      },
      "verify_check": {
        "has_verify_sh": true,
        "has_targeted_checks": true,
        "evidence_concrete": true,
        "notes": []
      },
      "scope_check": { "too_broad": false, "est_size_too_large": false, "notes": [] },
      "dependency_check": { "invalid": false, "forward_dep": false, "cycle": false, "notes": [] },
      "patch_suggestions": ["n/a"]
    }
  ]
}
JSON
  cat > "$cache" <<JSON
{
  "prd_sha256": "$prd_sha",
  "contract_sha256": "$contract_sha",
  "impl_plan_sha256": "$plan_sha",
  "workflow_contract_sha256": "$workflow_sha",
  "auditor_prompt_sha256": "$prompt_sha",
  "audited_scope": "full",
  "decision": "PASS"
}
JSON
  AUDIT_PRD_FILE="$prd" AUDIT_OUTPUT_JSON="$audit" AUDIT_CACHE_FILE="$cache" AUDITOR_AGENT_CMD="/usr/bin/false" ./plans/run_prd_auditor.sh >/dev/null 2>&1
'

echo "Test 0b: slice preflight blocks unresolved refs"
run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/audit_slice_preflight"
  mkdir -p "$tmpdir"
  prd="$tmpdir/prd.json"
  cat > "$prd" <<'JSON'
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
      "id": "S1-009",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Slice preflight unresolved refs test",
      "contract_refs": ["CONTRACT.md DOES_NOT_EXIST"],
      "plan_refs": ["Rust workspace exists with crates/soldier_core, crates/soldier_infra."],
      "scope": {
        "touch": ["docs/**"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
  CONTRACT_SOURCE_FILE="" CONTRACT_DIGEST_FILE="$tmpdir/contract_digest.json" ./plans/build_contract_digest.sh >/dev/null 2>&1
  PLAN_SOURCE_FILE="" PLAN_DIGEST_FILE="$tmpdir/plan_digest.json" ./plans/build_plan_digest.sh >/dev/null 2>&1
  set +e
  PRD_FILE="$prd" PRD_SLICE=1 CONTRACT_DIGEST="$tmpdir/contract_digest.json" PLAN_DIGEST="$tmpdir/plan_digest.json" OUT_PRD_SLICE="$tmpdir/prd_slice.json" OUT_CONTRACT_DIGEST="$tmpdir/contract_slice.json" OUT_PLAN_DIGEST="$tmpdir/plan_slice.json" OUT_META="$tmpdir/meta.json" ./plans/prd_slice_prepare.sh >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected prd_slice_prepare to fail on unresolved refs" >&2
    exit 1
  fi
'

echo "Test 0c: ref check blocks unresolved refs"
if run_in_worktree test -x "./plans/prd_ref_check.sh"; then
  run_in_worktree bash -c '
    set -euo pipefail
    tmpdir=".ralph/ref_check_bad"
    mkdir -p "$tmpdir"
    prd="$tmpdir/prd.json"
    cat > "$prd" <<JSON
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
      "id": "S1-010",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Ref check unresolved refs test",
      "contract_refs": ["CONTRACT.md DOES_NOT_EXIST"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md DOES_NOT_EXIST"],
      "scope": {
        "touch": ["docs/**"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
    set +e
    PRD_FILE="$prd" ./plans/prd_ref_check.sh >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      echo "FAIL: expected prd_ref_check to fail on unresolved refs" >&2
      exit 1
    fi
  '
else
  echo "SKIP: prd_ref_check.sh missing (ref check tests)"
fi

echo "Test 0d: ref check resolves slash + parenthetical variants"
if run_in_worktree test -x "./plans/prd_ref_check.sh"; then
  run_in_worktree bash -c '
    set -euo pipefail
    tmpdir=".ralph/ref_check_good"
    mkdir -p "$tmpdir"
    prd="$tmpdir/prd.json"
    cat > "$prd" <<'JSON'
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
      "id": "S1-011",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Ref check resolved refs test",
      "contract_refs": [
        "CONTRACT.md RiskState (health/cause layer): Healthy | Degraded | Maintenance | Kill",
        "CONTRACT.md If a mismatch is detected: **reject the intent** and set RiskState::Degraded"
      ],
      "plan_refs": [
        "Rust workspace exists with crates/soldier_core, crates/soldier_infra.",
        "IMPLEMENTATION_PLAN.md §Slice 1 — Instrument Units + Dispatcher Invariants / S1.1 — InstrumentKind derivation + instrument cache TTL (fail‑closed)"
      ],
      "scope": {
        "touch": ["docs/**"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
    PRD_FILE="$prd" ./plans/prd_ref_check.sh >/dev/null 2>&1
  '
else
  echo "SKIP: prd_ref_check.sh missing (ref check tests)"
fi

echo "Test 0: contract_check resolves contract refs without SIGPIPE"
reset_state
contract_test_root="$WORKTREE/.ralph/contract_check_ref_ok"
iter_dir="$contract_test_root/iter_1"
run_in_worktree mkdir -p "$iter_dir" "$contract_test_root/plans" "$contract_test_root/.ralph"
run_in_worktree bash -c "cd \"$contract_test_root\" && git init -q"
run_in_worktree bash -c "cd \"$contract_test_root\" && echo \"base\" > README.md && git add README.md && git -c user.name=\"workflow-acceptance\" -c user.email=\"workflow@local\" commit -m \"base\" >/dev/null"
run_in_worktree bash -c "cd \"$contract_test_root\" && echo \"update\" >> README.md && git add README.md && git -c user.name=\"workflow-acceptance\" -c user.email=\"workflow@local\" commit -m \"update\" >/dev/null"
cat > "$contract_test_root/CONTRACT.md" <<'EOF'
# Contract
## 1.0 Instrument Units
EOF
cat > "$contract_test_root/prd.json" <<'JSON'
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
      "id": "S1-008",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "slice_ref": "Slice 1",
      "story_ref": "Story 1",
      "category": "acceptance",
      "description": "Contract refs match test",
      "contract_refs": ["1.0 Instrument Units"],
      "plan_refs": ["IMPLEMENTATION_PLAN.md §1"],
      "scope": {
        "touch": ["docs/**"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "dependencies": [],
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
cat > "$iter_dir/selected.json" <<'JSON'
{"selected_id":"S1-008"}
JSON
run_in_worktree bash -c "cd \"$contract_test_root\" && git rev-parse HEAD~1 > \"$iter_dir/head_before.txt\""
run_in_worktree bash -c "cd \"$contract_test_root\" && git rev-parse HEAD > \"$iter_dir/head_after.txt\""
cp "$contract_test_root/prd.json" "$iter_dir/prd_before.json"
cp "$contract_test_root/prd.json" "$iter_dir/prd_after.json"
cat > "$iter_dir/diff.patch" <<'EOF'
diff --git a/docs/order_size_discovery.md b/docs/order_size_discovery.md
index 0000000..1111111 100644
--- a/docs/order_size_discovery.md
+++ b/docs/order_size_discovery.md
@@ -0,0 +1 @@
+test
EOF
echo "VERIFY_SH_SHA=stub" > "$iter_dir/verify_post.log"
cat > "$contract_test_root/.ralph/state.json" <<'JSON'
{"last_verify_post_rc":0}
JSON
cp "$ROOT/plans/contract_check.sh" "$contract_test_root/plans/contract_check.sh"
cp "$ROOT/plans/contract_review_validate.sh" "$contract_test_root/plans/contract_review_validate.sh"
chmod +x "$contract_test_root/plans/contract_check.sh" "$contract_test_root/plans/contract_review_validate.sh"
set +e
run_in_worktree env \
  CONTRACT_REVIEW_OUT="$iter_dir/contract_review.json" \
  CONTRACT_FILE="$contract_test_root/CONTRACT.md" \
  PRD_FILE="$contract_test_root/prd.json" \
  RPH_STATE_FILE="$contract_test_root/.ralph/state.json" \
  CONTRACT_REVIEW_SCHEMA="$ROOT/docs/schemas/contract_review.schema.json" \
  bash -c "cd \"$contract_test_root\" && ./plans/contract_check.sh \"$iter_dir/contract_review.json\"" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected contract_check.sh to exit 0 for matching contract_refs" >&2
  exit 1
fi
decision="$(run_in_worktree jq -r '.decision' "$iter_dir/contract_review.json")"
if [[ "$decision" != "PASS" ]]; then
  echo "FAIL: expected decision=PASS for matching contract_refs, got ${decision}" >&2
  exit 1
fi
if run_in_worktree jq -e '.violations[]? | select(.contract_ref=="CONTRACT_REFS")' "$iter_dir/contract_review.json" >/dev/null 2>&1; then
  echo "FAIL: unexpected CONTRACT_REFS violation for matching contract_refs" >&2
  exit 1
fi
write_contract_check_stub "PASS"
run_in_worktree git update-index --skip-worktree plans/contract_check.sh >/dev/null 2>&1 || true

echo "Test 1: schema-violating PRD stops preflight"
run_in_worktree mkdir -p .ralph
reset_state
invalid_prd="$WORKTREE/.ralph/invalid_prd.json"
write_invalid_prd "$invalid_prd"
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env PRD_FILE="$invalid_prd" PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" RPH_DRY_RUN=1 RPH_RATE_LIMIT_ENABLED=0 RPH_SELECTION_MODE=harness ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for invalid PRD" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "invalid_prd_schema" >/dev/null; then
  exit 1
fi

echo "Test 2: attempted pass flip without verify_post is prevented"
reset_state
valid_prd_2="$WORKTREE/.ralph/valid_prd_2.json"
write_valid_prd "$valid_prd_2" "S1-001"
run_id="$(next_run_id)"
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
  PRD_FILE="$valid_prd_2" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_once_then_fail.sh" \
  VERIFY_COUNT_FILE="$WORKTREE/.ralph/verify_count_test2" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-001" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  RPH_RUN_ID="$run_id" \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when verify_post fails" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "verify_post_failed" >/dev/null; then
  exit 1
fi
pass_state="$(run_in_worktree jq -r '.items[0].passes' "$valid_prd_2")"
if [[ "$pass_state" != "false" ]]; then
  echo "FAIL: passes flipped without verify_post green" >&2
  exit 1
fi
manifest_path=".ralph/artifacts.json"
if ! run_in_worktree test -f "$manifest_path"; then
  echo "FAIL: expected manifest for verify_post failure" >&2
  exit 1
fi
if ! assert_manifest_valid "$manifest_path"; then
  exit 1
fi
if ! assert_manifest_run_id "$manifest_path" "$run_id"; then
  exit 1
fi
manifest_status="$(run_in_worktree jq -r '.final_verify_status' "$manifest_path")"
if [[ "$manifest_status" != "BLOCKED" ]]; then
  echo "FAIL: expected final_verify_status=BLOCKED on verify_post failure" >&2
  exit 1
fi
blocked_reason="$(run_in_worktree jq -r '.blocked_reason' "$manifest_path")"
if [[ "$blocked_reason" != "verify_post_failed" ]]; then
  echo "FAIL: expected blocked_reason=verify_post_failed" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.skipped_checks[]? | select(.name=="story_verify" and .reason=="verify_post_failed")' "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected skipped_checks verify_post_failed entry in manifest" >&2
  exit 1
fi
agent_model="$(run_in_worktree jq -r '.agent_model // empty' "$WORKTREE/.ralph/state.json" 2>/dev/null || true)"
if [[ -z "$agent_model" ]]; then
  echo "FAIL: expected agent_model recorded in state.json" >&2
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json" 2>/dev/null || true)"
if [[ -z "$iter_dir" ]]; then
  echo "FAIL: expected last_iter_dir in state.json" >&2
  exit 1
fi
if ! run_in_worktree test -f "$iter_dir/agent_model.txt"; then
  echo "FAIL: expected agent_model.txt in iteration artifacts" >&2
  exit 1
fi
iter_model="$(run_in_worktree cat "$iter_dir/agent_model.txt" 2>/dev/null || true)"
if [[ -z "$iter_model" ]]; then
  echo "FAIL: agent_model.txt is empty" >&2
  exit 1
fi

echo "Test 2b: mark_pass without meaningful change is blocked"
reset_state
valid_prd_2b="$WORKTREE/.ralph/valid_prd_2b.json"
write_valid_prd "$valid_prd_2b" "S1-001"
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_2b" \
  PROGRESS_FILE="$WORKTREE/plans/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_meta_only.sh" \
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
  echo "FAIL: expected non-zero exit for mark_pass without meaningful change" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "pass_flip_no_touch" >/dev/null; then
  exit 1
fi

echo "Test 2c: mark_pass promotes verify mode"
reset_state
valid_prd_2c="$WORKTREE/.ralph/valid_prd_2c.json"
write_valid_prd "$valid_prd_2c" "S1-002"
set +e
test2c_log="$WORKTREE/.ralph/test2c.log"
run_in_worktree env \
  PRD_FILE="$valid_prd_2c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_record_mode.sh" \
  RPH_VERIFY_MODE=quick \
  RPH_PROMOTION_VERIFY_MODE=promotion \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-002" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >"$test2c_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for verify promotion test" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test2c_log" >&2 || true
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json" || true)"
verify_post_log="$WORKTREE/$iter_dir/verify_post.log"
if [[ ! -f "$verify_post_log" ]]; then
  echo "FAIL: expected verify_post.log for promotion test" >&2
  exit 1
fi
if ! grep -q "VERIFY_MODE_ARG=promotion" "$verify_post_log"; then
  echo "FAIL: expected verify_post to run in promotion mode for mark_pass" >&2
  echo "verify_post.log:" >&2
  tail -n 20 "$verify_post_log" >&2 || true
  exit 1
fi

echo "Test 2d: update_task requires promotion verify mode"
reset_state
valid_prd_2d="$WORKTREE/.ralph/valid_prd_2d.json"
write_valid_prd "$valid_prd_2d" "S1-003"
state_dir="$WORKTREE/.ralph"
mkdir -p "$state_dir"
state_file="$state_dir/state.json"
verify_log_path="$state_dir/verify_post_stub.log"
cat > "$verify_log_path" <<'EOF'
VERIFY_SH_SHA=stub
mode=full verify_mode=none root=/tmp
EOF
verify_log_sha="$(run_in_worktree sh -c 'sha256sum .ralph/verify_post_stub.log 2>/dev/null | cut -d " " -f1' || true)"
if [[ -z "$verify_log_sha" ]]; then
  verify_log_sha="$(run_in_worktree sh -c 'shasum -a 256 .ralph/verify_post_stub.log | cut -d " " -f1' || true)"
fi
current_head="$(run_in_worktree git rev-parse HEAD)"
cat > "$state_file" <<JSON
{
  "selected_id": "S1-003",
  "last_verify_post_rc": 0,
  "last_verify_post_head": "${current_head}",
  "last_verify_post_log": ".ralph/verify_post_stub.log",
  "last_verify_post_log_sha256": "${verify_log_sha}",
  "last_verify_post_mode": "full",
  "last_verify_post_verify_mode": "none",
  "last_verify_post_cmd": "./plans/verify.sh full",
  "last_verify_post_verify_sh_sha": "stub"
}
JSON
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_2d" \
  RPH_UPDATE_TASK_OK=1 \
  ./plans/update_task.sh "S1-003" true >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected update_task to reject non-promotion verify mode" >&2
  exit 1
fi

echo "Test 2e: explore profile forbids mark_pass"
reset_state
valid_prd_2e="$WORKTREE/.ralph/valid_prd_2e.json"
write_valid_prd "$valid_prd_2e" "S1-020"
before_blocked="$(snapshot_blocked_dirs)"
set +e
test2e_log="$WORKTREE/.ralph/test2e.log"
run_ralph env \
  PRD_FILE="$valid_prd_2e" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_progress.sh" \
  SELECTED_ID="S1-020" \
  RPH_PROFILE="explore" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >"$test2e_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when mark_pass is forbidden in explore profile" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "mark_pass_forbidden" >/dev/null; then
  echo "Ralph log tail:" >&2
  tail -n 120 "$test2e_log" >&2 || true
  exit 1
fi

echo "Test 2f: promote profile requires promotion verify"
reset_state
valid_prd_2f="$WORKTREE/.ralph/valid_prd_2f.json"
write_valid_prd "$valid_prd_2f" "S1-021"
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
  PRD_FILE="$valid_prd_2f" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_PROFILE="promote" \
  RPH_PROMOTION_VERIFY_MODE="full" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when promote profile runs without promotion verify" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "profile_requires_promotion_verify" >/dev/null; then
  exit 1
fi

echo "Test 3: COMPLETE printed early blocks with blocked_incomplete artifact"
reset_state
valid_prd_3="$WORKTREE/.ralph/valid_prd_3.json"
write_valid_prd "$valid_prd_3" "S1-002"
before_blocked="$(snapshot_blocked_dirs)"
set +e
test3_log="$WORKTREE/.ralph/test3.log"
run_ralph env \
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
blocked_dir="$(assert_new_blocked_with_reason "$before_blocked" "incomplete_completion")"
if [[ -z "$blocked_dir" ]]; then
  echo "Blocked dirs:" >&2
  find "$WORKTREE/.ralph" -maxdepth 1 -type d -name 'blocked_*' -print >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test3_log" >&2 || true
  exit 1
fi
if [[ "$blocked_dir" != *"blocked_incomplete_"* ]]; then
  echo "FAIL: expected blocked_incomplete_* artifact for premature COMPLETE" >&2
  exit 1
fi

echo "Test 3b: COMPLETE mention does not trigger blocked_incomplete"
reset_state
valid_prd_3b="$WORKTREE/.ralph/valid_prd_3b.json"
write_valid_prd "$valid_prd_3b" "S1-002"
before_blocked="$(snapshot_blocked_dirs)"
set +e
test3b_log="$WORKTREE/.ralph/test3b.log"
run_ralph env \
  PRD_FILE="$valid_prd_3b" \
  PROGRESS_FILE="$WORKTREE/plans/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mentions_complete.sh" \
  SELECTED_ID="S1-002" \
  ACCEPTANCE_TOUCH_FILE="src/lib.rs" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test3b_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for max iters when no completion" >&2
  exit 1
fi
after_blocked="$(snapshot_blocked_dirs)"
new_dirs="$(diff_blocked_dirs "$before_blocked" "$after_blocked")"
if [[ -z "$new_dirs" ]]; then
  echo "FAIL: expected blocked artifact for max iters" >&2
  exit 1
fi
if printf '%s\n' "$new_dirs" | grep -q 'blocked_incomplete_'; then
  echo "FAIL: did not expect blocked_incomplete artifact for COMPLETE mention" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test3b_log" >&2 || true
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "max_iters_exceeded" >/dev/null; then
  echo "Ralph log tail:" >&2
  tail -n 120 "$test3b_log" >&2 || true
  exit 1
fi

echo "Test 4: invalid selection writes verify_pre.log (best effort)"
reset_state
valid_prd_4="$WORKTREE/.ralph/valid_prd_4.json"
write_valid_prd "$valid_prd_4" "S1-003"
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
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
latest_block="$(assert_new_blocked_with_reason "$before_blocked" "invalid_selection")"
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
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
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
if ! assert_new_blocked_with_reason "$before_blocked" "lock_held" >/dev/null; then
  echo "FAIL: could not locate blocked artifact for lock_held" >&2
  exit 1
fi

echo "Test 5a: stale lock auto-clears"
reset_state
valid_prd_5a="$WORKTREE/.ralph/valid_prd_5a.json"
write_valid_prd "$valid_prd_5a" "S1-004"
mkdir -p "$WORKTREE/.ralph/lock"
old_ts="$(( $(date +%s) - 10 ))"
cat > "$WORKTREE/.ralph/lock/lock.json" <<JSON
{"pid":999999,"started_at":"2000-01-01T00:00:00Z","started_at_epoch":${old_ts}}
JSON
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_5a" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_LOCK_TTL_SECS=1 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected stale lock to be cleared" >&2
  exit 1
fi
if [[ -d "$WORKTREE/.ralph/lock" ]]; then
  echo "FAIL: expected lock directory to be released after stale lock test" >&2
  exit 1
fi

echo "Test 5b: git identity is set when missing"
reset_state
valid_prd_5b="$WORKTREE/.ralph/valid_prd_5b.json"
write_valid_prd "$valid_prd_5b" "S1-004"
run_in_worktree git config --local --unset-all user.email >/dev/null 2>&1 || true
run_in_worktree git config --local --unset-all user.name >/dev/null 2>&1 || true
set +e
run_in_worktree env \
  PRD_FILE="$valid_prd_5b" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_SYSTEM=/dev/null \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected preflight to set git identity" >&2
  exit 1
fi
git_email="$(run_in_worktree git config --local --get user.email || true)"
git_name="$(run_in_worktree git config --local --get user.name || true)"
if [[ "$git_email" != "ralph@local" || "$git_name" != "ralph" ]]; then
  echo "FAIL: expected git identity to be set locally (got name=${git_name} email=${git_email})" >&2
  exit 1
fi

echo "Test 5c: preflight blocks without timeout or python3"
reset_state
valid_prd_5c="$WORKTREE/.ralph/valid_prd_5c.json"
write_valid_prd "$valid_prd_5c" "S1-004"
no_timeout_bin="$WORKTREE/.ralph/no_timeout_bin"
rm -rf "$no_timeout_bin"
mkdir -p "$no_timeout_bin"
for cmd in bash git jq date dirname mkdir tee cp sed awk head tail sort tr stat; do
  cmd_path="$(command -v "$cmd" || true)"
  if [[ -z "$cmd_path" ]]; then
    echo "FAIL: required command missing for test setup: $cmd" >&2
    exit 1
  fi
  ln -s "$cmd_path" "$no_timeout_bin/$cmd"
done
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_in_worktree env \
  PATH="$no_timeout_bin" \
  PRD_FILE="$valid_prd_5c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected preflight to block without timeout/python3" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "missing_timeout_or_python3" >/dev/null; then
  echo "FAIL: expected missing_timeout_or_python3 blocked artifact" >&2
  exit 1
fi

echo "Test 5d: contract review sees iteration artifacts"
reset_state
valid_prd_5d="$WORKTREE/plans/prd_iter_artifacts.json"
write_valid_prd "$valid_prd_5d" "S1-004"
run_in_worktree git add "$valid_prd_5d" >/dev/null 2>&1
run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: iter artifacts prd" >/dev/null 2>&1
write_contract_check_stub_require_iter_artifacts
set +e
test5b_log="$WORKTREE/.ralph/test5b.log"
run_ralph env \
  PRD_FILE="$valid_prd_5d" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-004" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test5b_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for iter artifacts contract review" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test5b_log" >&2 || true
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
decision="$(run_in_worktree jq -r '.decision' "$iter_dir/contract_review.json")"
if [[ "$decision" != "PASS" ]]; then
  echo "FAIL: expected decision=PASS for iter artifacts check, got ${decision}" >&2
  exit 1
fi
write_contract_check_stub "PASS"

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
run_ralph env \
  PRD_FILE="$valid_prd_6" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
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
run_ralph env \
  PRD_FILE="$valid_prd_7" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
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
run_ralph env \
  PRD_FILE="$valid_prd_8" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
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
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
  PRD_FILE="$valid_prd_9" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-008" \
  RPH_PROFILE="promote" \
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
if ! assert_new_blocked_with_reason "$before_blocked" "contract_review_failed" >/dev/null; then
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
run_ralph env \
  PRD_FILE="$valid_prd_10" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-009" \
  RPH_VERIFY_MODE="promotion" \
  RPH_PROMOTION_VERIFY_MODE="promotion" \
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

echo "Test 10b: final verify uses RPH_FINAL_VERIFY_MODE"
reset_state
valid_prd_10b="$WORKTREE/.ralph/valid_prd_10b.json"
write_valid_prd "$valid_prd_10b" "S1-020"
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
run_id="$(next_run_id)"
set +e
test10b_log="$WORKTREE/.ralph/test10b.log"
run_ralph env \
  PRD_FILE="$valid_prd_10b" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass_mode.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-020" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  VERIFY_MODE="promotion" \
  RPH_VERIFY_MODE="quick" \
  RPH_FINAL_VERIFY=1 \
  RPH_FINAL_VERIFY_MODE="promotion" \
  RPH_PROMOTION_VERIFY_MODE="promotion" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  RPH_RUN_ID="$run_id" \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test10b_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for final verify mode test" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test10b_log" >&2 || true
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json")"
if [[ -z "$iter_dir" ]]; then
  echo "FAIL: expected last_iter_dir for final verify mode test" >&2
  exit 1
fi
if ! run_in_worktree grep -q "MODE_ARG=quick" "$iter_dir/verify_pre.log"; then
  echo "FAIL: expected verify_pre to use quick mode" >&2
  exit 1
fi
if ! run_in_worktree grep -q "MODE_ARG=promotion" "$iter_dir/verify_post.log"; then
  echo "FAIL: expected verify_post to use promotion mode on pass" >&2
  exit 1
fi
final_log="${iter_dir}/final_verify.log"
if ! run_in_worktree test -f "$final_log"; then
  echo "FAIL: expected final verify log in iteration directory for final verify mode test" >&2
  exit 1
fi
if ! run_in_worktree grep -q "MODE_ARG=promotion" "$final_log"; then
  echo "FAIL: expected final verify to use promotion mode" >&2
  exit 1
fi
manifest_path=".ralph/artifacts.json"
if ! run_in_worktree test -f "$manifest_path"; then
  echo "FAIL: expected artifact manifest at $manifest_path" >&2
  exit 1
fi
if ! assert_manifest_valid "$manifest_path"; then
  exit 1
fi
schema_version="$(run_in_worktree jq -r '.schema_version' "$manifest_path")"
if [[ "$schema_version" != "1" ]]; then
  echo "FAIL: expected schema_version=1" >&2
  exit 1
fi
if ! assert_manifest_run_id "$manifest_path" "$run_id"; then
  exit 1
fi
manifest_status="$(run_in_worktree jq -r '.final_verify_status' "$manifest_path")"
if [[ "$manifest_status" != "PASS" ]]; then
  echo "FAIL: expected final_verify_status=PASS" >&2
  exit 1
fi
manifest_final="$(run_in_worktree jq -r '.final_verify_log_path // empty' "$manifest_path")"
if [[ "$manifest_final" != "$final_log" ]]; then
  echo "FAIL: manifest final_verify_log_path mismatch" >&2
  exit 1
fi
manifest_contract="$(run_in_worktree jq -r '.contract_review_path // empty' "$manifest_path")"
if [[ "$manifest_contract" != "$iter_dir/contract_review.json" ]]; then
  echo "FAIL: manifest contract_review_path mismatch" >&2
  exit 1
fi
manifest_contract_check="$(run_in_worktree jq -r '.contract_check_report_path // empty' "$manifest_path")"
if [[ "$manifest_contract_check" != "$iter_dir/contract_review.json" ]]; then
  echo "FAIL: manifest contract_check_report_path mismatch" >&2
  exit 1
fi
manifest_commit_count="$(run_in_worktree jq -r '.commit_count' "$manifest_path")"
if [[ "$manifest_commit_count" != "1" ]]; then
  echo "FAIL: expected manifest commit_count=1" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.skipped_checks[]? | select(.name=="story_verify" and .reason=="no_story_verify_commands")' "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected skipped_checks story_verify entry in manifest" >&2
  exit 1
fi
write_contract_check_stub "PASS"


echo "Test 10c: final verify disabled writes SKIPPED manifest"
reset_state
valid_prd_10c="$WORKTREE/.ralph/valid_prd_10c.json"
write_valid_prd "$valid_prd_10c" "S1-021"
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
run_id="$(next_run_id)"
set +e
test10c_log="$WORKTREE/.ralph/test10c.log"
run_ralph env \
  PRD_FILE="$valid_prd_10c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass_mode.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-021" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_VERIFY_MODE="quick" \
  RPH_PROMOTION_VERIFY_MODE="promotion" \
  RPH_FINAL_VERIFY=0 \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  RPH_RUN_ID="$run_id" \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test10c_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected zero exit for final verify disabled test" >&2
  tail -n 120 "$test10c_log" >&2 || true
  exit 1
fi
manifest_path=".ralph/artifacts.json"
if ! assert_manifest_valid "$manifest_path"; then
  exit 1
fi
if ! assert_manifest_run_id "$manifest_path" "$run_id"; then
  exit 1
fi
manifest_status="$(run_in_worktree jq -r '.final_verify_status' "$manifest_path")"
if [[ "$manifest_status" != "SKIPPED" ]]; then
  echo "FAIL: expected final_verify_status=SKIPPED when disabled" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.skipped_checks[]? | select(.name=="final_verify" and .reason=="disabled")' "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected skipped_checks final_verify disabled" >&2
  exit 1
fi
write_contract_check_stub "PASS"

echo "Test 10c: update_task blocks non-promotion verify"
reset_state
valid_prd_10c="$WORKTREE/plans/prd_acceptance_non_promo.json"
write_valid_prd "$valid_prd_10c" "S1-010"
run_in_worktree git add "$valid_prd_10c" >/dev/null 2>&1
run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: seed prd non-promo" >/dev/null 2>&1
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
set +e
test10c_log="$WORKTREE/.ralph/test10c.log"
before_blocked="$(snapshot_blocked_dirs)"
run_ralph env \
  PRD_FILE="$valid_prd_10c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_full_no_promotion.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-010" \
  RPH_VERIFY_MODE="full" \
  RPH_PROMOTION_VERIFY_MODE="full" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test10c_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for non-promotion verify when marking pass" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test10c_log" >&2 || true
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "update_task_failed" >/dev/null; then
  echo "FAIL: expected update_task_failed blocked artifact" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test10c_log" >&2 || true
  exit 1
fi

write_contract_check_stub "PASS"

echo "Test 10d: final verify failure writes FAIL manifest"
reset_state
valid_prd_10d="$WORKTREE/.ralph/valid_prd_10d.json"
write_valid_prd "$valid_prd_10d" "S1-022"
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
run_id="$(next_run_id)"
set +e
test10d_log="$WORKTREE/.ralph/test10d.log"
run_ralph env \
  PRD_FILE="$valid_prd_10d" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_fail_on_mode.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
  SELECTED_ID="S1-022" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  VERIFY_MODE="promotion" \
  RPH_VERIFY_MODE="quick" \
  RPH_PROMOTION_VERIFY_MODE="full" \
  RPH_FINAL_VERIFY_MODE="promotion" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  RPH_RUN_ID="$run_id" \
  GIT_AUTHOR_NAME="workflow-acceptance" \
  GIT_AUTHOR_EMAIL="workflow@local" \
  GIT_COMMITTER_NAME="workflow-acceptance" \
  GIT_COMMITTER_EMAIL="workflow@local" \
  ./plans/ralph.sh 1 >"$test10d_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for final verify failure" >&2
  tail -n 120 "$test10d_log" >&2 || true
  exit 1
fi
manifest_path=".ralph/artifacts.json"
if ! assert_manifest_valid "$manifest_path"; then
  exit 1
fi
if ! assert_manifest_run_id "$manifest_path" "$run_id"; then
  exit 1
fi
manifest_status="$(run_in_worktree jq -r '.final_verify_status' "$manifest_path")"
if [[ "$manifest_status" != "FAIL" ]]; then
  echo "FAIL: expected final_verify_status=FAIL for final verify failure" >&2
  exit 1
fi
blocked_reason="$(run_in_worktree jq -r '.blocked_reason // empty' "$manifest_path")"
if [[ "$blocked_reason" != "final_verify_failed" ]]; then
  echo "FAIL: expected blocked_reason=final_verify_failed" >&2
  exit 1
fi
manifest_log="$(run_in_worktree jq -r '.final_verify_log_path // empty' "$manifest_path")"
if [[ -z "$manifest_log" || ! -f "$WORKTREE/$manifest_log" ]]; then
  echo "FAIL: expected final_verify_log_path to exist for failed final verify" >&2
  exit 1
fi
write_contract_check_stub "PASS"

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
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
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
if ! assert_new_blocked_with_reason "$before_blocked" "missing_prd" >/dev/null; then
  exit 1
fi

echo "Test 14: verify_pre failure stops before implementation"
reset_state
valid_prd_13="$WORKTREE/.ralph/valid_prd_13.json"
write_valid_prd "$valid_prd_13" "S1-010"
run_id="$(next_run_id)"
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
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
  RPH_RUN_ID="$run_id" \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for verify_pre failure" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "verify_pre_failed" >/dev/null; then
  echo "FAIL: expected verify_pre_failed blocked artifact" >&2
  exit 1
fi
manifest_path=".ralph/artifacts.json"
if ! run_in_worktree test -f "$manifest_path"; then
  echo "FAIL: expected manifest for verify_pre failure" >&2
  exit 1
fi
if ! assert_manifest_valid "$manifest_path"; then
  exit 1
fi
if ! assert_manifest_run_id "$manifest_path" "$run_id"; then
  exit 1
fi
manifest_status="$(run_in_worktree jq -r '.final_verify_status' "$manifest_path")"
if [[ "$manifest_status" != "BLOCKED" ]]; then
  echo "FAIL: expected final_verify_status=BLOCKED on verify_pre failure" >&2
  exit 1
fi
blocked_reason="$(run_in_worktree jq -r '.blocked_reason' "$manifest_path")"
if [[ "$blocked_reason" != "verify_pre_failed" ]]; then
  echo "FAIL: expected blocked_reason=verify_pre_failed" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.skipped_checks[]? | select(.name=="final_verify" and .reason=="verify_pre_failed")' "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected final_verify skipped entry for verify_pre failure" >&2
  exit 1
fi
dirty_status="$(run_in_worktree git status --porcelain)"
if [[ -n "$dirty_status" ]]; then
  echo "FAIL: expected clean worktree after verify_pre failure" >&2
  echo "$dirty_status" >&2
  exit 1
fi

echo "Test 14b: verify output is tailed and summary created"
reset_state
valid_prd_14b="$WORKTREE/.ralph/valid_prd_14b.json"
write_valid_prd "$valid_prd_14b" "S1-010"
run_in_worktree mkdir -p .ralph
verify_tail_log="$WORKTREE/.ralph/verify_tail_test.log"
set +e
run_ralph env \
  PRD_FILE="$valid_prd_14b" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_fail_noisy.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass.sh" \
  SELECTED_ID="S1-010" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  RPH_VERIFY_FAIL_TAIL=40 \
  RPH_VERIFY_SUMMARY_MAX=5 \
  ./plans/ralph.sh 1 > "$verify_tail_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for noisy verify_pre failure" >&2
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json" 2>/dev/null || true)"
if [[ -z "$iter_dir" ]]; then
  echo "FAIL: expected last_iter_dir for noisy verify_pre test" >&2
  exit 1
fi
summary_path="$WORKTREE/$iter_dir/verify_summary.txt"
if [[ ! -f "$summary_path" ]]; then
  echo "FAIL: expected verify_summary.txt at $summary_path" >&2
  exit 1
fi
if ! grep -q "error: noisy failure" "$summary_path"; then
  echo "FAIL: expected noisy error line in verify_summary.txt" >&2
  exit 1
fi
if ! grep -q "FAILED noisy_test" "$summary_path"; then
  echo "FAIL: expected FAILED line in verify_summary.txt" >&2
  exit 1
fi
if ! grep -q "panicked" "$summary_path"; then
  echo "FAIL: expected panicked line in verify_summary.txt" >&2
  exit 1
fi
if grep -q "line 1" "$verify_tail_log"; then
  echo "FAIL: verify output should be tailed; found early lines in log" >&2
  exit 1
fi
if ! grep -q "line 300" "$verify_tail_log"; then
  echo "FAIL: expected tail of noisy output to include line 300" >&2
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
before_blocked="$(snapshot_blocked_dirs)"
# Modify to set needs_human_decision=true
_tmp=$(mktemp)
run_in_worktree jq '.items[0].needs_human_decision = true | .items[0].human_blocker = {"why":"test","question":"?","options":["A"],"recommended":"A","unblock_steps":["fix"]}' "$valid_prd_14" > "$_tmp" && mv "$_tmp" "$valid_prd_14"
set +e
run_ralph env \
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
if ! assert_new_blocked_with_reason "$before_blocked" "needs_human_decision" >/dev/null; then
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

before_blocked="$(snapshot_blocked_dirs)"
set +e
test16_log="$WORKTREE/.ralph/test16.log"
run_ralph env \
  PRD_FILE="$valid_prd_15" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_delete_test_file_and_commit.sh" \
  RPH_CHEAT_DETECTION="block" \
  RPH_SELF_HEAL=1 \
  RPH_SELECTION_MODE=harness \
  ./plans/ralph.sh 1 >"$test16_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 9 ]]; then
  echo "FAIL: expected exit code 9 for cheating (deleted test), got $rc" >&2
  tail -n 120 "$test16_log" >&2 || true
  exit 1
fi
latest_block="$(assert_new_blocked_with_reason "$before_blocked" "cheating_detected" || true)"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for cheating_detected" >&2
  tail -n 120 "$test16_log" >&2 || true
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

echo "Test 16b: harness tamper blocks before processing"
reset_state
valid_prd_16b="$WORKTREE/.ralph/valid_prd_16b.json"
write_valid_prd "$valid_prd_16b" "S1-011"
before_blocked="$(snapshot_blocked_dirs)"
set +e
test16b_log="$WORKTREE/.ralph/test16b.log"
run_in_worktree env \
  PRD_FILE="$valid_prd_16b" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_modify_harness.sh" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >"$test16b_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for harness tamper" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "harness_sha_mismatch" >/dev/null; then
  echo "FAIL: expected blocked artifact for harness_sha_mismatch" >&2
  tail -n 120 "$test16b_log" >&2 || true
  exit 1
fi
copy_worktree_file "plans/ralph.sh"
chmod +x "$WORKTREE/plans/ralph.sh" >/dev/null 2>&1 || true
run_in_worktree git update-index --skip-worktree plans/ralph.sh >/dev/null 2>&1 || true

echo "Test 16c: .ralph tamper blocks before processing"
reset_state
valid_prd_16c="$WORKTREE/.ralph/valid_prd_16c.json"
write_valid_prd "$valid_prd_16c" "S1-012"
before_blocked="$(snapshot_blocked_dirs)"
set +e
test16c_log="$WORKTREE/.ralph/test16c.log"
run_in_worktree env \
  PRD_FILE="$valid_prd_16c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_modify_ralph_state.sh" \
  RPH_PROMPT_FLAG="" \
  RPH_AGENT_ARGS="" \
  RPH_RATE_LIMIT_ENABLED=0 \
  RPH_SELECTION_MODE=harness \
  RPH_SELF_HEAL=0 \
  ./plans/ralph.sh 1 >"$test16c_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for .ralph tamper" >&2
  exit 1
fi
if ! assert_new_blocked_with_reason "$before_blocked" "ralph_dir_modified" >/dev/null; then
  echo "FAIL: expected blocked artifact for ralph_dir_modified" >&2
  tail -n 120 "$test16c_log" >&2 || true
  exit 1
fi

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
run_ralph env \
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
run_ralph env \
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
run_ralph env \
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
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
  PRD_FILE="$valid_prd_19" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_once_then_fail.sh" \
  VERIFY_COUNT_FILE="$WORKTREE/.ralph/verify_count_test19" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mark_pass_with_commit.sh" \
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
if ! assert_new_blocked_with_reason "$before_blocked" "circuit_breaker" >/dev/null; then
  echo "FAIL: expected blocked artifact for circuit_breaker" >&2
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
before_blocked="$(snapshot_blocked_dirs)"
set +e
run_ralph env \
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
if ! assert_new_blocked_with_reason "$before_blocked" "max_iters_exceeded" >/dev/null; then
  echo "FAIL: expected blocked artifact for max_iters_exceeded" >&2
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
run_ralph env \
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

echo "Test 22: contract kernel validates against sources (fail-closed)"
if ! run_in_worktree test -f "docs/contract_kernel.json"; then
  echo "FAIL: docs/contract_kernel.json missing" >&2
  exit 1
fi
kernel_log="$WORKTREE/.ralph/contract_kernel_check.log"
if ! run_in_worktree python3 scripts/check_contract_kernel.py >"$kernel_log" 2>&1; then
  echo "FAIL: contract kernel validation failed" >&2
  tail -n 120 "$kernel_log" >&2 || true
  exit 1
fi

echo "Workflow acceptance tests passed"
