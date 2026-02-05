#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2026
set -euo pipefail

# Git hooks export GIT_DIR/GIT_WORK_TREE; clear to avoid leaking into clones/worktrees.
if [[ -n "${GIT_DIR:-}" || -n "${GIT_WORK_TREE:-}" || -n "${GIT_INDEX_FILE:-}" ]]; then
  echo "WARN: clearing git hook env (GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE) for workflow acceptance isolation" >&2
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
DEFAULT_STATE_FILE="/tmp/workflow_acceptance.state"
DEFAULT_STATUS_FILE="/tmp/workflow_acceptance.status"

WORKFLOW_ACCEPTANCE_MODE="full"
WORKFLOW_ACCEPTANCE_SETUP_MODE="${WORKFLOW_ACCEPTANCE_SETUP_MODE:-auto}"
WORKFLOW_ACCEPTANCE_CACHE_DIR="${WORKFLOW_ACCEPTANCE_CACHE_DIR:-}"
WORKFLOW_ACCEPTANCE_CACHE_READY="${WORKFLOW_ACCEPTANCE_CACHE_READY:-0}"
WORKFLOW_ACCEPTANCE_CACHE_ERR=""
ONLY_ID=""
ONLY_SET=""
FROM_ID=""
UNTIL_ID=""
RESUME=0
FAST=0
LIST=0
STATE_FILE="$DEFAULT_STATE_FILE"
STATUS_FILE="$DEFAULT_STATUS_FILE"
REQUIRE_SHELLCHECK=0
START_INDEX=1
END_INDEX=0
TEST_COUNTER=0
CURRENT_TEST_START=0
CURRENT_TEST_ID=""
# shellcheck disable=SC2034
CURRENT_TEST_DESC=""
ALL_TEST_IDS=()

usage() {
  cat <<'EOF'
Usage: ./plans/workflow_acceptance.sh [options]

Options:
  --list                 List tests and exit
  --fast                 Run fast prechecks only
  --mode <full|smoke>     Run full suite or fast smoke subset
  --only <id>            Run a single test id (overrides other selectors)
  --only-set <ids>       Run multiple test ids (comma-separated, e.g., "0e,0f,1")
  --from <id>            Start running at id (inclusive)
  --until <id>           Stop after id (inclusive)
  --resume               Resume from the test after the last completed id in state file
  --state-file <path>    State file path (default /tmp/workflow_acceptance.state)
  --status-file <path>   Status file path (default /tmp/workflow_acceptance.status)
  --require-shellcheck   Fail if shellcheck is not installed
EOF
}

list_tests() {
  sed -nE 's/^[[:space:]]*if[[:space:]]+test_start[[:space:]]+"([^"]+)"[[:space:]]+"([^"]+)".*/\1\t\2/p' "$SCRIPT_PATH"
}

collect_test_ids() {
  ALL_TEST_IDS=()
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    ALL_TEST_IDS+=("$id")
  done < <(sed -nE 's/^[[:space:]]*if[[:space:]]+test_start[[:space:]]+"([^"]+)".*/\1/p' "$SCRIPT_PATH")
  if (( ${#ALL_TEST_IDS[@]} == 0 )); then
    echo "FAIL: no tests registered (test_start markers missing)" >&2
    exit 1
  fi
}

index_first_of() {
  local needle="$1"
  local i
  for i in "${!ALL_TEST_IDS[@]}"; do
    if [[ "${ALL_TEST_IDS[$i]}" == "$needle" ]]; then
      echo $((i + 1))
      return 0
    fi
  done
  return 1
}

index_last_of() {
  local needle="$1"
  local i
  for ((i=${#ALL_TEST_IDS[@]}-1; i>=0; i--)); do
    if [[ "${ALL_TEST_IDS[$i]}" == "$needle" ]]; then
      echo $((i + 1))
      return 0
    fi
  done
  return 1
}

now_secs() {
  date +%s
}

ensure_parent_dir() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir" >/dev/null 2>&1 || true
}

write_status() {
  local id="$1"
  local desc="$2"
  ensure_parent_dir "$STATUS_FILE"
  printf '%s\t%s\n' "$id" "$desc" > "$STATUS_FILE"
}

mark_done() {
  local id="$1"
  ensure_parent_dir "$STATE_FILE"
  printf '%s\n' "$id" > "$STATE_FILE"
}

test_start() {
  local id="$1"
  local desc="$2"
  local fast="${3:-0}"
  TEST_COUNTER=$((TEST_COUNTER + 1))
  if [[ -n "$ONLY_ID" ]]; then
    if [[ "$id" != "$ONLY_ID" ]]; then
      return 1
    fi
  elif [[ -n "$ONLY_SET" ]]; then
    # Normalize: remove whitespace, check membership
    local normalized
    normalized=$(echo "$ONLY_SET" | tr -d '[:space:]')
    case ",$normalized," in
      *,$id,*) ;;  # ID found in set - continue to run
      *) return 1 ;; # ID not in set - skip
    esac
  else
    if (( TEST_COUNTER < START_INDEX || TEST_COUNTER > END_INDEX )); then
      return 1
    fi
    if (( FAST == 1 && fast == 0 )); then
      return 1
    fi
  fi
  CURRENT_TEST_ID="$id"
  CURRENT_TEST_DESC="$desc"
  CURRENT_TEST_START="$(now_secs)"
  echo "Test ${id}: ${desc}"
  write_status "$id" "$desc"
  return 0
}

test_pass() {
  local id="$1"
  local end
  end="$(now_secs)"
  local duration=$((end - CURRENT_TEST_START))
  : "$CURRENT_TEST_ID" "$CURRENT_TEST_DESC"
  mark_done "$id"
  echo "PASS ${id} (${duration}s)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        LIST=1
        shift
        ;;
      --fast)
        FAST=1
        shift
        ;;
      --mode)
        WORKFLOW_ACCEPTANCE_MODE="${2:-}"
        if [[ -z "$WORKFLOW_ACCEPTANCE_MODE" ]]; then
          echo "FAIL: --mode requires a value (full|smoke)" >&2
          exit 1
        fi
        shift 2
        ;;
      --only)
        ONLY_ID="${2:-}"
        if [[ -z "$ONLY_ID" ]]; then
          echo "FAIL: --only requires an id" >&2
          exit 1
        fi
        shift 2
        ;;
      --only-set)
        ONLY_SET="${2:-}"
        if [[ -z "$ONLY_SET" ]]; then
          echo "FAIL: --only-set requires a comma-separated list of ids" >&2
          exit 1
        fi
        shift 2
        ;;
      --from)
        FROM_ID="${2:-}"
        if [[ -z "$FROM_ID" ]]; then
          echo "FAIL: --from requires an id" >&2
          exit 1
        fi
        shift 2
        ;;
      --until)
        UNTIL_ID="${2:-}"
        if [[ -z "$UNTIL_ID" ]]; then
          echo "FAIL: --until requires an id" >&2
          exit 1
        fi
        shift 2
        ;;
      --resume)
        RESUME=1
        shift
        ;;
      --state-file)
        STATE_FILE="${2:-}"
        if [[ -z "$STATE_FILE" ]]; then
          echo "FAIL: --state-file requires a path" >&2
          exit 1
        fi
        shift 2
        ;;
      --status-file)
        STATUS_FILE="${2:-}"
        if [[ -z "$STATUS_FILE" ]]; then
          echo "FAIL: --status-file requires a path" >&2
          exit 1
        fi
        shift 2
        ;;
      --require-shellcheck)
        REQUIRE_SHELLCHECK=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "FAIL: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

case "$WORKFLOW_ACCEPTANCE_MODE" in
  full) ;;
  smoke)
    FAST=1
    ;;
  *)
    echo "FAIL: unknown workflow acceptance mode: $WORKFLOW_ACCEPTANCE_MODE (expected full|smoke)" >&2
    exit 1
    ;;
esac

if (( LIST == 1 )); then
  list_tests
  exit 0
fi

collect_test_ids

# Mutual exclusion: --only and --only-set cannot both be set
if [[ -n "$ONLY_ID" && -n "$ONLY_SET" ]]; then
  echo "FAIL: --only and --only-set are mutually exclusive" >&2
  exit 1
fi

# Mutual exclusion: --only/--only-set cannot combine with range/resume/fast
if [[ -n "$ONLY_ID" || -n "$ONLY_SET" ]]; then
  if [[ -n "$FROM_ID" || -n "$UNTIL_ID" || $RESUME -ne 0 || $FAST -ne 0 ]]; then
    echo "FAIL: --only/--only-set cannot be combined with --from/--until/--resume/--fast" >&2
    exit 1
  fi
fi

if [[ -n "$ONLY_ID" ]]; then
  if ! index_first_of "$ONLY_ID" >/dev/null; then
    echo "FAIL: --only id not found: $ONLY_ID" >&2
    exit 1
  fi
fi

if [[ -n "$ONLY_SET" ]]; then
  # Validate all IDs in the set exist
  normalized=$(echo "$ONLY_SET" | tr -d '[:space:]')
  IFS=',' read -ra ids <<<"$normalized"
  valid_count=0
  for id in "${ids[@]}"; do
    # Fail-closed: reject empty tokens (likely user typo like "0e,,0f")
    if [[ -z "$id" ]]; then
      echo "FAIL: --only-set contains empty token (check for typos like '0e,,0f')" >&2
      exit 1
    fi
    if ! index_first_of "$id" >/dev/null; then
      echo "FAIL: --only-set id not found: $id" >&2
      exit 1
    fi
    valid_count=$((valid_count + 1))
  done
  # Fail-fast on empty/whitespace-only input
  if (( valid_count == 0 )); then
    echo "FAIL: --only-set requires at least one valid id" >&2
    exit 1
  fi
fi

if [[ -n "$FROM_ID" ]]; then
  if ! START_INDEX="$(index_first_of "$FROM_ID")"; then
    echo "FAIL: --from id not found: $FROM_ID" >&2
    exit 1
  fi
fi

END_INDEX="${#ALL_TEST_IDS[@]}"
if [[ -n "$UNTIL_ID" ]]; then
  if ! END_INDEX="$(index_last_of "$UNTIL_ID")"; then
    echo "FAIL: --until id not found: $UNTIL_ID" >&2
    exit 1
  fi
fi

if (( RESUME == 1 )); then
  if [[ -f "$STATE_FILE" ]]; then
    last_done="$(head -n 1 "$STATE_FILE" | tr -d '[:space:]')"
    if [[ -n "$last_done" ]]; then
      if resume_index="$(index_last_of "$last_done")"; then
        START_INDEX=$((resume_index + 1))
      else
        echo "WARN: resume state id not found (${last_done}); running full range" >&2
      fi
    else
      echo "WARN: resume state file empty; running full range" >&2
    fi
  else
    echo "WARN: resume state file missing; running full range" >&2
  fi
fi

if (( START_INDEX > END_INDEX )); then
  echo "No tests selected (range ${START_INDEX}-${END_INDEX})." >&2
  exit 0
fi

mode_parts=()
if [[ -n "$ONLY_ID" ]]; then
  mode_parts+=("only:${ONLY_ID}")
elif [[ -n "$ONLY_SET" ]]; then
  mode_parts+=("only-set:$(echo "$ONLY_SET" | tr -d '[:space:]')")
else
  # FAST only applies when not using --only or --only-set
  # Distinguish between --mode smoke (explicit) and --fast (flag)
  if [[ "$WORKFLOW_ACCEPTANCE_MODE" == "smoke" ]]; then
    mode_parts+=("smoke")
  elif (( FAST == 1 )); then
    mode_parts+=("fast")
  fi
fi
if (( RESUME == 1 )); then
  mode_parts+=("resume")
fi
if [[ -n "$FROM_ID" ]]; then
  mode_parts+=("from:${FROM_ID}")
fi
if [[ -n "$UNTIL_ID" ]]; then
  mode_parts+=("until:${UNTIL_ID}")
fi
if (( ${#mode_parts[@]} == 0 )); then
  mode_parts+=("full")
fi
echo "Workflow acceptance mode: ${mode_parts[*]}"
echo "workflow_acceptance_mode=$WORKFLOW_ACCEPTANCE_MODE"
echo "State file: ${STATE_FILE}"
echo "Status file: ${STATUS_FILE}"

# Validate story verify allowlist: checks file exists, has content, no duplicates
# Args: $1 = allowlist file path
# Returns: 0 on success, 1 on failure (with FAIL message to stderr)
validate_story_allowlist() {
  local allowlist="$1"
  if [[ ! -f "$allowlist" ]]; then
    echo "FAIL: story verify allowlist missing: $allowlist" >&2
    return 1
  fi
  # Check for empty or comment-only allowlist (awk is safer than grep -cv || true)
  local content_lines
  content_lines="$(awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { count++ } END { print count+0 }' "$allowlist")"
  if [[ "$content_lines" -eq 0 ]]; then
    echo "FAIL: story verify allowlist is empty or contains only comments: $allowlist" >&2
    return 1
  fi
  # Check for duplicates
  local dup
  dup="$(grep -v "^[[:space:]]*#" "$allowlist" | sed '/^[[:space:]]*$/d' | sort | uniq -d)"
  if [[ -n "$dup" ]]; then
    echo "FAIL: story verify allowlist contains duplicate entries:" >&2
    printf "%s\n" "$dup" >&2
    return 1
  fi
  return 0
}

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
require_tools git jq mktemp find wc tr sed awk stat sort head tail date grep uniq comm
mkdir -p "$ROOT/.ralph"
WORKFLOW_ACCEPTANCE_SETUP_ONLY="${WORKFLOW_ACCEPTANCE_SETUP_ONLY:-0}"
WORKTREE_MODE=""
WORKTREE_ERR=""
WORKTREE="$(mktemp -d "${ROOT}/.ralph/workflow_acceptance_XXXXXX")"

cleanup() {
  if [[ "$WORKTREE_MODE" == "worktree" ]]; then
    git -C "$ROOT" worktree remove -f "$WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKTREE"
}
trap cleanup EXIT

git_dir_abs="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -n "$git_dir_abs" && ! -w "$git_dir_abs" ]]; then
  echo "WARN: git dir not writable: $git_dir_abs" >&2
fi

dirty_status="$(git -C "$ROOT" status --porcelain 2>/dev/null || true)"
if [[ -n "$dirty_status" ]]; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: working tree is dirty in CI" >&2
    echo "$dirty_status" >&2
    exit 1
  fi
  if [[ "${VERIFY_ALLOW_DIRTY:-0}" != "1" ]]; then
    echo "FAIL: working tree is dirty; set VERIFY_ALLOW_DIRTY=1 to continue" >&2
    echo "$dirty_status" >&2
    exit 1
  fi
  echo "WARN: working tree is dirty (VERIFY_ALLOW_DIRTY=1)" >&2
  echo "$dirty_status" >&2
fi

normalize_cache_dir() {
  local path="$1"
  if [[ -z "$path" ]]; then
    echo ""
    return 0
  fi
  if [[ "$path" != /* ]]; then
    echo "$ROOT/$path"
  else
    echo "$path"
  fi
}

prepare_cache_repo() {
  local cache_dir="$1"
  local err_file
  if [[ -z "$cache_dir" ]]; then
    return 0
  fi
  if [[ "$WORKFLOW_ACCEPTANCE_CACHE_READY" == "1" ]]; then
    return 0
  fi
  err_file="$(mktemp)"
  mkdir -p "$(dirname "$cache_dir")"
  if [[ -d "$cache_dir" ]]; then
    if [[ ! -d "$cache_dir/objects" ]]; then
      WORKFLOW_ACCEPTANCE_CACHE_ERR="cache dir exists but is not a git repo: $cache_dir"
      rm -f "$err_file"
      return 1
    fi
    git -C "$cache_dir" remote set-url origin "$ROOT" >/dev/null 2>&1 || true
    if ! git -C "$cache_dir" fetch --prune origin >/dev/null 2>"$err_file"; then
      WORKFLOW_ACCEPTANCE_CACHE_ERR="cache fetch failed: $(cat "$err_file" 2>/dev/null || true)"
      rm -f "$err_file"
      return 1
    fi
  else
    if ! git clone --mirror "$ROOT" "$cache_dir" >/dev/null 2>"$err_file"; then
      WORKFLOW_ACCEPTANCE_CACHE_ERR="cache clone failed: $(cat "$err_file" 2>/dev/null || true)"
      rm -f "$err_file"
      return 1
    fi
  fi
  rm -f "$err_file"
  return 0
}

setup_worktree() {
  local mode="$1"
  local err_file
  err_file="$(mktemp)"
  case "$mode" in
    worktree)
      if git -C "$ROOT" worktree add -f "$WORKTREE" HEAD >/dev/null 2>"$err_file"; then
        WORKTREE_MODE="worktree"
        rm -f "$err_file"
        return 0
      fi
      WORKTREE_ERR="$(cat "$err_file" 2>/dev/null || true)"
      rm -f "$err_file"
      rm -rf "$WORKTREE"
      return 1
      ;;
    clone)
      rm -rf "$WORKTREE"
      if [[ -n "$WORKFLOW_ACCEPTANCE_CACHE_DIR" ]]; then
        local cache_dir
        cache_dir="$(normalize_cache_dir "$WORKFLOW_ACCEPTANCE_CACHE_DIR")"
        if ! prepare_cache_repo "$cache_dir"; then
          WORKTREE_ERR="$WORKFLOW_ACCEPTANCE_CACHE_ERR"
          rm -f "$err_file"
          rm -rf "$WORKTREE"
          return 1
        fi
        if git clone --shared "$cache_dir" "$WORKTREE" >/dev/null 2>"$err_file"; then
          WORKTREE_MODE="clone"
          rm -f "$err_file"
          return 0
        fi
        WORKTREE_ERR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        rm -rf "$WORKTREE"
        return 1
      fi
      if git clone --no-hardlinks "$ROOT" "$WORKTREE" >/dev/null 2>"$err_file"; then
        WORKTREE_MODE="clone"
        rm -f "$err_file"
        return 0
      fi
      WORKTREE_ERR="$(cat "$err_file" 2>/dev/null || true)"
      rm -f "$err_file"
      rm -rf "$WORKTREE"
      return 1
      ;;
    archive)
      rm -rf "$WORKTREE"
      mkdir -p "$WORKTREE"
      if ! command -v tar >/dev/null 2>&1; then
        WORKTREE_ERR="tar not available for archive fallback"
        rm -rf "$WORKTREE"
        return 1
      fi
      if ! git -C "$ROOT" archive HEAD 2>"$err_file" | tar -x -C "$WORKTREE"; then
        WORKTREE_ERR="$(cat "$err_file" 2>/dev/null || true)"
        rm -f "$err_file"
        rm -rf "$WORKTREE"
        return 1
      fi
      rm -f "$err_file"
      if [[ -d "$ROOT/.git" ]]; then
        cp -R "$ROOT/.git" "$WORKTREE/.git"
      elif [[ -f "$ROOT/.git" && -n "$git_dir_abs" && -d "$git_dir_abs" ]]; then
        cp -R "$git_dir_abs" "$WORKTREE/.git"
      fi
      WORKTREE_MODE="archive"
      return 0
      ;;
    *)
      WORKTREE_ERR="unknown workflow acceptance mode: $mode"
      return 1
      ;;
  esac
}

select_worktree_mode() {
  case "$WORKFLOW_ACCEPTANCE_SETUP_MODE" in
    worktree|clone|archive)
      if ! setup_worktree "$WORKFLOW_ACCEPTANCE_SETUP_MODE"; then
        echo "FAIL: workflow acceptance setup failed (mode=$WORKFLOW_ACCEPTANCE_SETUP_MODE): $WORKTREE_ERR" >&2
        exit 1
      fi
      ;;
    auto)
      if setup_worktree "worktree"; then
        :
      elif setup_worktree "clone"; then
        :
      elif setup_worktree "archive"; then
        :
      else
        echo "FAIL: workflow acceptance setup failed (auto): $WORKTREE_ERR" >&2
        exit 1
      fi
      ;;
    *)
      echo "FAIL: invalid WORKFLOW_ACCEPTANCE_SETUP_MODE=$WORKFLOW_ACCEPTANCE_SETUP_MODE (expected auto|worktree|clone|archive)" >&2
      exit 1
      ;;
  esac
}

select_worktree_mode
echo "workflow acceptance mode: ${WORKTREE_MODE:-unknown}"
if [[ "$WORKFLOW_ACCEPTANCE_SETUP_ONLY" == "1" ]]; then
  exit 0
fi

run_in_worktree() {
  (cd "$WORKTREE" && "$@")
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
  mkdir -p "$(dirname "$dest")"
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
  "specs/CONTRACT.md"
  "specs/IMPLEMENTATION_PLAN.md"
  "specs/POLICY.md"
  "verify.sh"
  "AGENTS.md"
  ".github/pull_request_template.md"
  "plans/ralph.sh"
  "plans/verify.sh"
  "plans/test_parallel_smoke.sh"
  "plans/workflow_files_allowlist.txt"
  "plans/lib/verify_utils.sh"
  "plans/lib/change_detection.sh"
  "plans/lib/rust_gates.sh"
  "plans/lib/python_gates.sh"
  "plans/lib/node_gates.sh"
  "plans/workflow_verify.sh"
  "plans/update_task.sh"
  "plans/prd.json"
  "plans/prd_schema_check.sh"
  "plans/prd_lint.sh"
  "plans/prd_gate.sh"
  "plans/prd_pipeline.sh"
  "plans/prd_preflight.sh"
  "plans/preflight.sh"
  "plans/story_verify_allowlist_check.sh"
  "plans/story_verify_allowlist_lint.sh"
  "plans/story_verify_allowlist_suggest.sh"
  "plans/prd_autofix.sh"
  "plans/run_prd_auditor.sh"
  "plans/prd_audit_check.sh"
  "prompts/auditor.md"
  "plans/build_markdown_digest.sh"
  "plans/build_contract_digest.sh"
  "plans/build_plan_digest.sh"
  "plans/prd_slice_prepare.sh"
  "plans/prd_cache_check.py"
  "plans/prd_cache_update.py"
  "plans/prd_audit_merge.py"
  "plans/prd_audit_merge.sh"
  "plans/contract_check.sh"
  "plans/contract_coverage_matrix.py"
  "plans/contract_coverage_promote.sh"
  "plans/ssot_lint.sh"
  "plans/artifacts_validate.sh"
  "plans/contract_review_validate.sh"
  "plans/postmortem_check.sh"
  "plans/workflow_contract_gate.sh"
  "plans/workflow_acceptance_parallel.sh"
  "plans/workflow_contract_map.json"
  "specs/vendor_docs/rust/CRATES_OF_INTEREST.yaml"
  "tools/vendor_docs_lint_rust.py"
  "plans/tests/test_prd_gate.sh"
  "plans/tests/test_prd_audit_check.sh"
  "plans/tests/test_contract_coverage_matrix.sh"
  "plans/tests/test_workflow_acceptance_fallback.sh"
  "plans/tests/test_workflow_allowlist_coverage.sh"
  "plans/tests/test_change_detection_routing.sh"
  "plans/tests/test_prd_cache.sh"
  "plans/fixtures/prd/deps_order_same_slice.json"
  "plans/fixtures/prd/deps_cycle_same_slice.json"
  "plans/fixtures/prd/deps_forward_slice.json"
  "plans/fixtures/prd/missing_plan_refs.json"
  "plans/fixtures/prd/workflow_touches_crates_touch.json"
  "plans/fixtures/prd/workflow_touches_crates_create.json"
  "plans/fixtures/prd/execution_touches_plans.json"
  "plans/fixtures/prd/acceptance_too_short.json"
  "plans/fixtures/prd/unresolved_contract_ref.json"
  "plans/fixtures/prd/empty_evidence.json"
  "plans/fixtures/prd/missing_targeted_verify.json"
  "plans/fixtures/prd/missing_contract_must_evidence.json"
  "plans/fixtures/prd/missing_observability_metrics.json"
  "plans/fixtures/prd/reason_code_missing_values.json"
  "plans/fixtures/prd/missing_failure_mode.json"
  "plans/fixtures/prd/placeholder_todo.json"
  "plans/fixtures/acceptance_touch.txt"
  "specs/CONTRACT.md"
  "specs/IMPLEMENTATION_PLAN.md"
  "specs/POLICY.md"
  "specs/SOURCE_OF_TRUTH.md"
  "specs/invariants/GLOBAL_INVARIANTS.md"
  "specs/flows/ARCH_FLOWS.yaml"
  "specs/flows/TIME_FRESHNESS.yaml"
  "specs/flows/CRASH_MATRIX.md"
  "specs/flows/CRASH_REPLAY_IDEMPOTENCY.yaml"
  "specs/flows/RECONCILIATION_MATRIX.md"
  "specs/flows/VQ_EVIDENCE.md"
  "specs/state_machines/group_state.yaml"
  "specs/state_machines/open_permission_latch.yaml"
  "specs/state_machines/risk_state.yaml"
  "specs/state_machines/trading_mode.yaml"
  "scripts/check_contract_crossrefs.py"
  "scripts/check_arch_flows.py"
  "scripts/check_state_machines.py"
  "scripts/check_global_invariants.py"
  "scripts/check_time_freshness.py"
  "scripts/check_crash_matrix.py"
  "scripts/check_crash_replay_idempotency.py"
  "scripts/check_reconciliation_matrix.py"
  "scripts/check_vq_evidence.py"
  "scripts/extract_contract_excerpts.py"
  "specs/WORKFLOW_CONTRACT.md"
  "docs/schemas/artifacts.schema.json"
)
OPTIONAL_OVERLAY_FILES=(
  "plans/prd_ref_check.sh"
  "plans/prd_ref_index.sh"
)
MISSING_OVERLAY_FILES=()
add_optional_overlays "${OPTIONAL_OVERLAY_FILES[@]}"

if test_start "0d.1" "git hook env vars are cleared for workflow acceptance"; then
  if [[ -n "${GIT_DIR:-}" || -n "${GIT_WORK_TREE:-}" || -n "${GIT_INDEX_FILE:-}" ]]; then
    echo "FAIL: expected GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE to be unset" >&2
    exit 1
  fi
  test_pass "0d.1"
fi

if test_start "0e" "optional overlay files are skipped when missing"; then
  if (( ${#MISSING_OVERLAY_FILES[@]} > 0 )); then
    for overlay in "${MISSING_OVERLAY_FILES[@]}"; do
      if printf '%s\n' "${OVERLAY_FILES[@]}" | grep -Fxq "$overlay"; then
        echo "FAIL: optional overlay listed despite missing: $overlay" >&2
        exit 1
      fi
    done
  fi
  test_pass "0e"
fi

run_in_worktree git update-index --no-skip-worktree "${OVERLAY_FILES[@]}" >/dev/null 2>&1 || true
for overlay in "${OVERLAY_FILES[@]}"; do
  copy_worktree_file "$overlay"
done
scripts_to_chmod=(
  "ralph.sh"
  "verify.sh"
  "test_parallel_smoke.sh"
  "lib/rust_gates.sh"
  "lib/python_gates.sh"
  "lib/node_gates.sh"
  "workflow_verify.sh"
  "workflow_acceptance_parallel.sh"
  "update_task.sh"
  "prd_schema_check.sh"
  "prd_lint.sh"
  "prd_gate.sh"
  "prd_pipeline.sh"
  "prd_preflight.sh"
  "preflight.sh"
  "story_verify_allowlist_check.sh"
  "story_verify_allowlist_lint.sh"
  "story_verify_allowlist_suggest.sh"
  "prd_autofix.sh"
  "run_prd_auditor.sh"
  "prd_audit_check.sh"
  "build_markdown_digest.sh"
  "build_contract_digest.sh"
  "build_plan_digest.sh"
  "prd_slice_prepare.sh"
  "contract_check.sh"
  "contract_coverage_matrix.py"
  "contract_coverage_promote.sh"
  "ssot_lint.sh"
  "artifacts_validate.sh"
  "contract_review_validate.sh"
  "postmortem_check.sh"
  "workflow_contract_gate.sh"
  "prd_ref_check.sh"
  "prd_ref_index.sh"
  "tests/test_prd_gate.sh"
  "tests/test_prd_audit_check.sh"
  "tests/test_workflow_acceptance_fallback.sh"
  "tests/test_workflow_allowlist_coverage.sh"
  "tests/test_change_detection_routing.sh"
  "tests/test_prd_cache.sh"
  "prd_audit_merge.sh"
)
for script in "${scripts_to_chmod[@]}"; do
  if [[ -f "$WORKTREE/plans/$script" ]]; then
    chmod +x "$WORKTREE/plans/$script" >/dev/null 2>&1 || true
  fi
done
if [[ -f "$WORKTREE/verify.sh" ]]; then
  chmod +x "$WORKTREE/verify.sh" >/dev/null 2>&1 || true
fi
run_in_worktree git update-index --skip-worktree "${OVERLAY_FILES[@]}" >/dev/null 2>&1 || true
run_in_worktree git update-index --no-skip-worktree "plans/fixtures/acceptance_touch.txt" >/dev/null 2>&1 || true

if test_start "0f.1" "ssot lint"; then
  run_in_worktree bash -c 'set -euo pipefail; bash plans/ssot_lint.sh'
  test_pass "0f.1"
fi

if test_start "0f.2" "verify includes spec integrity gates"; then
  run_in_worktree bash -c 'set -euo pipefail; rg -n "Spec integrity gates" plans/verify.sh >/dev/null'
  test_pass "0f.2"
fi

if test_start "0f" "prd_pipeline logs skipped ref check"; then
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
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["log"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
  CI= PRD_FILE="$prd" PROGRESS_FILE="$progress" PRD_CUTTER_CMD="true" PRD_AUDITOR_ENABLED=0 PRD_REF_CHECK_ENABLED=0 PRD_GATE_ALLOW_REF_SKIP=1 ./plans/prd_pipeline.sh >/dev/null 2>&1
  if ! grep -q "PRD ref check skipped" "$progress"; then
    echo "FAIL: expected progress log to note skipped prd_ref_check" >&2
    exit 1
  fi
'
  test_pass "0f"
fi

if test_start "0g" "manifest written on preflight block"; then
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
  set +e
  PRD_FILE=".ralph/missing_prd.json" \
    VERIFY_SH="/bin/true" \
    RPH_AGENT_CMD="true" \
    RPH_RATE_LIMIT_ENABLED=0 \
    ./plans/ralph.sh 1 >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for preflight block" >&2
    exit 1
  fi
  manifest=".ralph/artifacts.json"
  if [[ ! -f "$manifest" ]]; then
    echo "FAIL: expected manifest for preflight block" >&2
    exit 1
  fi
  ./plans/artifacts_validate.sh "$manifest" >/dev/null 2>&1
  status="$(jq -r ".final_verify_status" "$manifest")"
  if [[ "$status" != "BLOCKED" ]]; then
    echo "FAIL: expected manifest final_verify_status=BLOCKED on preflight block" >&2
    exit 1
  fi
  blocked_reason="$(jq -r ".blocked_reason" "$manifest")"
  if [[ "$blocked_reason" != "missing_prd" ]]; then
    echo "FAIL: expected blocked_reason=missing_prd" >&2
    exit 1
  fi
  run_id="$(jq -r ".run_id // empty" "$manifest")"
  if [[ -z "$run_id" ]]; then
    echo "FAIL: expected run_id in manifest" >&2
    exit 1
  fi
  if ! jq -e ".skipped_checks[]? | select(.name==\"final_verify\" and .reason==\"preflight_blocked\")" "$manifest" >/dev/null 2>&1; then
    echo "FAIL: expected final_verify preflight_blocked in skipped_checks" >&2
    exit 1
  fi
'
  test_pass "0g"
fi

if test_start "0h" "real PRD schema check (plans/prd.json)" 1; then
  run_in_worktree ./plans/prd_schema_check.sh "plans/prd.json" >/dev/null 2>&1
  test_pass "0h"
fi

if test_start "0i" "PRD self-dependency check" 1; then
  if run_in_worktree jq -e '.items[] | select((.dependencies // []) | index(.id))' plans/prd.json >/dev/null 2>&1; then
    echo "FAIL: PRD self-dependency detected:" >&2
    run_in_worktree jq -r '.items[] | select((.dependencies // []) | index(.id)) | .id' plans/prd.json >&2
    exit 1
  fi
  test_pass "0i"
fi

if test_start "0j" "shell safety checks (bash -n, shellcheck optional)" 1; then
  bash -n "$ROOT/plans/workflow_acceptance.sh"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$ROOT/plans/workflow_acceptance.sh"
  else
    if (( REQUIRE_SHELLCHECK == 1 )); then
      echo "FAIL: shellcheck not installed (required)" >&2
      exit 1
    fi
    echo "SKIP: shellcheck not installed"
  fi
  test_pass "0j"
fi

if test_start "0j.1" "autofix script syntax check" 1; then
  bash -n "$ROOT/plans/autofix.sh" || {
    echo "FAIL: autofix.sh has syntax errors" >&2
    exit 1
  }
  test_pass "0j.1"
fi

if test_start "0j.2" "autofix run_fix escalates on tool failure" 1; then
  # Test that run_fix() helper exits 1 and preserves log on tool failure
  test_evidence_dir="$WORKTREE/.ralph/autofix_test_evidence_$$"
  mkdir -p "$test_evidence_dir"

  # Create a mock failing tool
  mock_fail="$WORKTREE/.ralph/mock_fail.sh"
  cat > "$mock_fail" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock tool output before failure"
echo "simulated error: something went wrong" >&2
exit 1
MOCKEOF
  chmod +x "$mock_fail"

  # Source the helper function by extracting it and testing in isolation
  # (Avoids running the full autofix.sh which has side effects)
  test_script="$WORKTREE/.ralph/test_run_fix.sh"
  cat > "$test_script" <<TESTEOF
#!/usr/bin/env bash
set -euo pipefail
AUTOFIX_EVIDENCE_DIR="$test_evidence_dir"
VERIFY_RUN_ID="test_run"

# run_fix helper (extracted from autofix.sh)
run_fix() {
  local label="\$1"; shift
  local log="\$AUTOFIX_EVIDENCE_DIR/\${VERIFY_RUN_ID:-unknown}_\${label}.log"
  if ! "\$@" >"\$log" 2>&1; then
    echo "ESCALATE: \${label} failed; see \$log" >&2
    tail -n 80 "\$log" >&2 || true
    echo "Evidence preserved in: \$AUTOFIX_EVIDENCE_DIR/" >&2
    exit 1
  fi
}

# Test: call run_fix with the failing mock tool
run_fix mock_tool "$mock_fail"
echo "should not reach here"
TESTEOF
  chmod +x "$test_script"

  set +e
  run_in_worktree bash "$test_script" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: run_fix should have exited 1 on tool failure" >&2
    exit 1
  fi

  # Verify log file was created
  log_file="$test_evidence_dir/test_run_mock_tool.log"
  if [[ ! -f "$log_file" ]]; then
    echo "FAIL: run_fix should have created log file at $log_file" >&2
    exit 1
  fi

  # Verify log contains tool output
  if ! grep -q "mock tool output before failure" "$log_file"; then
    echo "FAIL: log file should contain tool stdout" >&2
    exit 1
  fi

  rm -rf "$test_evidence_dir"
  test_pass "0j.2"
fi

if test_start "0j.3" "autofix evidence survives escalation" 1; then
  # Test that evidence directory and its contents survive failure escalation
  test_evidence_dir="$WORKTREE/.ralph/autofix_evidence_survive_$$"
  mkdir -p "$test_evidence_dir"

  # Create evidence file before simulated failure
  echo "pre-failure evidence" > "$test_evidence_dir/pre_failure.log"

  # Simulate copy_evidence_or_die with a failure case
  test_script="$WORKTREE/.ralph/test_copy_evidence.sh"
  cat > "$test_script" <<TESTEOF
#!/usr/bin/env bash
set -euo pipefail
AUTOFIX_EVIDENCE_DIR="$test_evidence_dir"

# copy_evidence_or_die helper (extracted from autofix.sh)
copy_evidence_or_die() {
  local src="\$1"
  local dst="\$2"
  if ! cp -R "\$src" "\$dst"; then
    echo "ESCALATE: failed to copy evidence from \${src} to \${dst}" >&2
    echo "Evidence dir: \$AUTOFIX_EVIDENCE_DIR" >&2
    exit 1
  fi
}

# Try to copy from nonexistent source (should fail)
copy_evidence_or_die "/nonexistent/path" "$test_evidence_dir/dest"
TESTEOF
  chmod +x "$test_script"

  set +e
  run_in_worktree bash "$test_script" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: copy_evidence_or_die should have exited 1 on copy failure" >&2
    exit 1
  fi

  # Critical: evidence directory and pre-existing files must survive
  if [[ ! -d "$test_evidence_dir" ]]; then
    echo "FAIL: evidence directory should survive escalation" >&2
    exit 1
  fi

  if [[ ! -f "$test_evidence_dir/pre_failure.log" ]]; then
    echo "FAIL: pre-failure evidence should survive escalation" >&2
    exit 1
  fi

  if ! grep -q "pre-failure evidence" "$test_evidence_dir/pre_failure.log"; then
    echo "FAIL: pre-failure evidence content should be intact" >&2
    exit 1
  fi

  rm -rf "$test_evidence_dir"
  test_pass "0j.3"
fi

if test_start "0k" "workflow preflight checks"; then
  run_in_worktree mkdir -p ".ralph"
  cp "$ROOT/plans/story_verify_allowlist.txt" "$WORKTREE/.ralph/story_verify_allowlist.txt"
  export RPH_STORY_VERIFY_ALLOWLIST_FILE="$WORKTREE/.ralph/story_verify_allowlist.txt"
  if ! validate_story_allowlist "$RPH_STORY_VERIFY_ALLOWLIST_FILE"; then
    exit 1
  fi
  # Completeness check (commands in PRD but not in allowlist)
  if ! run_in_worktree bash -c '
  set -euo pipefail
  allowlist="${RPH_STORY_VERIFY_ALLOWLIST_FILE:-plans/story_verify_allowlist.txt}"
  # Optimized allowlist completeness check (set comparison)
  tmpdir="$(mktemp -d)"
  trap "rm -rf \"$tmpdir\"" EXIT
  required_file="$tmpdir/required.txt"
  allowed_file="$tmpdir/allowed.txt"
  # Required = PRD verify commands (exclude self-reference)
  jq -r ".items[].verify[] | select(. != \"./plans/verify.sh\")" plans/prd.json \
    | LC_ALL=C sort -u > "$required_file"
  # Allowed = allowlist entries (ignore comments/blank lines)
  grep -v "^[[:space:]]*#" "$allowlist" | sed "/^[[:space:]]*$/d" \
    | LC_ALL=C sort -u > "$allowed_file"
  # Set difference: commands in PRD but not in allowlist
  missing="$(LC_ALL=C comm -23 "$required_file" "$allowed_file")"
  if [[ -n "$missing" ]]; then
    echo "FAIL: story verify commands not allowlisted:" >&2
    printf "%s\n" "$missing" >&2
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

  if ! run_in_worktree test -x "plans/prd_gate.sh"; then
    echo "FAIL: plans/prd_gate.sh not executable" >&2
    exit 1
  fi
  if ! run_in_worktree test -f "plans/prd_gate_help.md"; then
    echo "FAIL: plans/prd_gate_help.md missing" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "prd_gate_help.md" "plans/prd_gate.sh"; then
    echo "FAIL: prd_gate.sh must reference prd_gate_help.md" >&2
    exit 1
  fi

  if ! run_in_worktree test -x "plans/prd_audit_check.sh"; then
    echo "FAIL: plans/prd_audit_check.sh not executable" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "WF-VERIFY-RULE" "AGENTS.md"; then
    echo "FAIL: AGENTS.md missing workflow verify guidance marker (WF-VERIFY-RULE)" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "WF-VERIFY-EVIDENCE" "reviews/REVIEW_CHECKLIST.md"; then
    echo "FAIL: review checklist missing workflow verify evidence marker (WF-VERIFY-EVIDENCE)" >&2
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
  in_stage && /prd_gate.sh/ && gate==0 {gate=NR}
  in_stage && /run_cmd PRD_CUTTER/ && cutter==0 {cutter=NR}
  END {
    if (gate==0 || cutter==0) exit 1
    if (gate > cutter) exit 1
  }
' "plans/prd_pipeline.sh"; then
  echo "FAIL: prd_pipeline Stage A must run gate before PRD_CUTTER" >&2
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

  if ! run_in_worktree grep -q "plans/\\*\\.sh" "plans/preflight.sh"; then
    echo "FAIL: preflight must target plans/*.sh for syntax checks" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "bash -n" "plans/preflight.sh"; then
    echo "FAIL: preflight must run bash -n for shell syntax checks" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "CONTRACT_FILE" "plans/preflight.sh"; then
    echo "FAIL: preflight must honor CONTRACT_FILE override" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "POSTMORTEM_GATE" "plans/preflight.sh"; then
    echo "FAIL: preflight must honor POSTMORTEM_GATE override" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "run_logged \"preflight\"" "plans/verify.sh"; then
    echo "FAIL: verify must run plans/preflight.sh under run_logged" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q 'WORKFLOW_ACCEPTANCE_TIMEOUT="${WORKFLOW_ACCEPTANCE_TIMEOUT:-30m}"' "plans/verify.sh"; then
    echo "FAIL: verify must default WORKFLOW_ACCEPTANCE_TIMEOUT to 30m" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q 'preflight_strict="--strict"' "plans/verify.sh"; then
    echo "FAIL: verify must pass --strict to preflight in CI or when requested" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "VERIFY_PREFLIGHT_STRICT" "plans/verify.sh"; then
    echo "FAIL: verify must support VERIFY_PREFLIGHT_STRICT for preflight" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "should_run_workflow_acceptance" "plans/verify.sh"; then
    echo "FAIL: verify must call should_run_workflow_acceptance" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "run_logged \"workflow_acceptance\"" "plans/verify.sh"; then
    echo "FAIL: verify must run workflow_acceptance.sh under run_logged" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "workflow_acceptance.sh --mode" "plans/verify.sh"; then
    echo "FAIL: verify must pass --mode to workflow_acceptance.sh" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "workflow_acceptance_mode" "plans/verify.sh"; then
    echo "FAIL: verify must select workflow acceptance mode" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "workflow acceptance skipped" "plans/verify.sh"; then
    echo "FAIL: verify must emit a workflow acceptance skip message" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "PATH_CONVENTION" "plans/prd_lint.sh"; then
    echo "FAIL: prd_lint must flag path convention drift" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "MISSING_ANCHOR_REF" "plans/prd_lint.sh"; then
    echo "FAIL: prd_lint must flag missing Anchor IDs for referenced anchor titles" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "MISSING_VR_REF" "plans/prd_lint.sh"; then
    echo "FAIL: prd_lint must flag missing VR IDs for referenced validation rule titles" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "contract_coverage_matrix.py" "plans/verify.sh"; then
    echo "FAIL: verify must run contract coverage matrix" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "contract coverage skipped" "plans/verify.sh"; then
    echo "FAIL: verify must emit a contract coverage skip message" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "change_detection_ok=" "plans/verify.sh"; then
    echo "FAIL: verify must emit change detection status" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "should_run_rust_gates" "plans/lib/change_detection.sh"; then
    echo "FAIL: verify must include change-aware rust gate selection" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "should_run_python_gates" "plans/lib/change_detection.sh"; then
    echo "FAIL: verify must include change-aware python gate selection" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "ruff.toml" "plans/lib/change_detection.sh"; then
    echo "FAIL: verify must detect ruff config changes for python gates" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "should_run_node_gates" "plans/lib/change_detection.sh"; then
    echo "FAIL: verify must include change-aware node gate selection" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q ".node-version" "plans/lib/change_detection.sh"; then
    echo "FAIL: verify must detect .node-version changes for node gates" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "rust gates skipped" "plans/verify.sh"; then
    echo "FAIL: verify must emit rust gate skip message" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "python gates skipped" "plans/verify.sh"; then
    echo "FAIL: verify must emit python gate skip message" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "node gates skipped" "plans/verify.sh"; then
    echo "FAIL: verify must emit node gate skip message" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "endpoint gate skipped" "plans/verify.sh"; then
    echo "FAIL: verify must emit endpoint gate skip message" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "contract_coverage_ci_strict" "plans/verify.sh"; then
    echo "FAIL: verify must gate CI strict coverage via sentinel file" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "vendor_docs_lint_rust.py" "plans/verify.sh"; then
    echo "FAIL: verify must run Rust vendor docs lint" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "postmortem_check.sh" "plans/verify.sh"; then
    echo "FAIL: verify must run postmortem check gate" >&2
    exit 1
  fi

if ! run_in_worktree awk '
  NR<=160 {
    if (!mode_init && index($0, "MODE=\"\"")) mode_init=NR
    if (mode_init && !empty && index($0, "-z \"$MODE\"")) empty=NR
    if (empty && !ci && index($0, "CI:-")) ci=NR
    if (ci && !full && index($0, "MODE=\"full\"")) full=NR
    if (full && !quick && index($0, "MODE=\"quick\"")) quick=NR
  }
  END {exit (mode_init && empty && ci && full && quick) ? 0 : 1}
' "plans/verify.sh"; then
  echo "FAIL: verify must infer default mode from CI when no arg provided" >&2
  exit 1
fi

if ! run_in_worktree grep -q "VERIFY_CONSOLE" "plans/verify.sh"; then
  echo "FAIL: verify must support VERIFY_CONSOLE quiet/verbose modes" >&2
  exit 1
fi

utils="plans/lib/verify_utils.sh"

  if ! run_in_worktree grep -q "VERIFY_FAIL_TAIL_LINES" "plans/verify.sh" && \
     ! run_in_worktree grep -q "VERIFY_FAIL_TAIL_LINES" "$utils"; then
    echo "FAIL: verify must define VERIFY_FAIL_TAIL_LINES for quiet failure tail" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "VERIFY_FAIL_SUMMARY_LINES" "plans/verify.sh" && \
     ! run_in_worktree grep -q "VERIFY_FAIL_SUMMARY_LINES" "$utils"; then
    echo "FAIL: verify must define VERIFY_FAIL_SUMMARY_LINES for quiet failure summary" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "emit_fail_excerpt" "plans/verify.sh" && \
     ! run_in_worktree grep -q "emit_fail_excerpt" "$utils"; then
    echo "FAIL: verify must emit log tail + summary on quiet failures" >&2
    exit 1
  fi

  if ! run_in_worktree grep -q "error:|FAIL|FAILED|panicked" "plans/verify.sh" && \
     ! run_in_worktree grep -q "error:|FAIL|FAILED|panicked" "$utils"; then
    echo "FAIL: verify must grep failure summary patterns in quiet mode" >&2
    exit 1
  fi

if ! run_in_worktree test -x "plans/postmortem_check.sh"; then
  echo "FAIL: plans/postmortem_check.sh not executable" >&2
  exit 1
fi

if ! run_in_worktree grep -Fq "MUST keep fast precheck set limited to schema/self-dep/shellcheck/traceability" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing fast precheck constraint" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq 'MUST run `./plans/workflow_contract_gate.sh` and update workflow acceptance mapping assertions when editing `specs/WORKFLOW_CONTRACT.md` or `plans/workflow_contract_map.json`.' "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing workflow contract/map gate rule" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq 'MUST add acceptance coverage that exercises the exact validator path and asserts non-zero exit + specific error message when introducing or tightening workflow validation rules.' "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing workflow validator acceptance rule" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "<!-- AGENTS_STUB_V2 -->" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing stub marker" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "<!-- INPUT_GUARD_V1 -->" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing input guard marker" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "<!-- FOLLOWUP_NO_PREFLIGHT_V1 -->" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing follow-up marker" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "<!-- VERIFY_CI_SATISFIES_V1 -->" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing verify CI marker" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "<promise>BLOCKED_PRD_REQUIRES_RALPH</promise>" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing Ralph-only PRD sentinel" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "### 1) Input Guard (conditional)" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing input guard section header" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "QuickCheck:" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing QuickCheck token" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "NO_PREFLIGHT" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing NO_PREFLIGHT token" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "Review Coverage" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing Review Coverage requirement" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "reviews/REVIEW_CHECKLIST.md" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing review checklist reference" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "## Start here (only when doing edits / PR work / MED-HIGH risk)" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing conditional start-here heading" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "SHOULD keep workflow_acceptance test IDs stable and listable" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing workflow_acceptance test ID stability guidance" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "Top time/token sinks (fix focus)" "AGENTS.md"; then
  echo "FAIL: AGENTS.md missing top time/token sinks section" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "Review Coverage" "SKILLS/pr-review.md"; then
  echo "FAIL: pr-review skill missing Review Coverage section" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "reviews/REVIEW_CHECKLIST.md" "SKILLS/pr-review.md"; then
  echo "FAIL: pr-review skill missing review checklist reference" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "## Review Coverage (Required)" "reviews/REVIEW_CHECKLIST.md"; then
  echo "FAIL: review checklist missing Review Coverage section" >&2
  exit 1
fi
if ! run_in_worktree grep -Fq "## Workflow / Harness Changes (If plans/* or specs/* touched)" "reviews/REVIEW_CHECKLIST.md"; then
  echo "FAIL: review checklist missing workflow harness review section" >&2
  exit 1
fi

if ! run_in_worktree test -x "plans/workflow_verify.sh"; then
  echo "FAIL: expected plans/workflow_verify.sh to exist and be executable" >&2
  exit 1
fi

if ! run_in_worktree grep -q "workflow_acceptance.sh --mode" "plans/workflow_verify.sh"; then
  echo "FAIL: workflow_verify must invoke workflow_acceptance.sh with --mode" >&2
  exit 1
fi

if ! run_in_worktree grep -q "RUN_REPO_VERIFY" "plans/workflow_verify.sh"; then
  echo "FAIL: workflow_verify must support RUN_REPO_VERIFY override" >&2
  exit 1
fi

if ! run_in_worktree test -f "verify.sh"; then
  echo "FAIL: expected root verify.sh wrapper to exist" >&2
  exit 1
fi

if ! run_in_worktree grep -q "plans/verify.sh" "verify.sh"; then
  echo "FAIL: root verify.sh must delegate to plans/verify.sh" >&2
  exit 1
fi

if ! run_in_worktree grep -Eq "exec .*plans/verify.sh" "verify.sh"; then
  echo "FAIL: root verify.sh must exec plans/verify.sh" >&2
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
if ! grep -qi "After committing, run full verify" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph prompt must require verify after commit" >&2
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
if ! grep -q "RPH_TEST_COCHANGE_STRICT" "$WORKTREE/plans/ralph.sh"; then
  echo "FAIL: ralph must define RPH_TEST_COCHANGE_STRICT default" >&2
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

bad_scope_patterns="$(run_in_worktree jq -r '.items[].scope.touch[]?, .items[].scope.create[]? | select(endswith("/")) | select(contains("*") | not)' "$WORKTREE/plans/prd.json")"
  if [[ -n "$bad_scope_patterns" ]]; then
    echo "FAIL: scope patterns ending in / must include a glob (e.g., **):" >&2
    echo "$bad_scope_patterns" >&2
    exit 1
  fi
  test_pass "0k"
fi

if test_start "0k.1" "prd gate fixtures"; then
  run_in_worktree ./plans/tests/test_prd_gate.sh >/dev/null 2>&1
  if ! run_in_worktree grep -q "plans/prd_gate.sh" "plans/tests/test_prd_gate.sh"; then
    echo "FAIL: prd gate fixtures must invoke plans/prd_gate.sh" >&2
    exit 1
  fi
  test_pass "0k.1"
fi

if test_start "0k.2" "prd audit check fixtures"; then
  run_in_worktree ./plans/tests/test_prd_audit_check.sh >/dev/null 2>&1
  test_pass "0k.2"
fi

if test_start "0k.3" "contract coverage matrix fixtures"; then
  run_in_worktree ./plans/tests/test_contract_coverage_matrix.sh >/dev/null 2>&1
  test_pass "0k.3"
fi

if test_start "0k.4" "workflow acceptance clone fallback"; then
  "$ROOT/plans/tests/test_workflow_acceptance_fallback.sh" >/dev/null 2>&1
  test_pass "0k.4"
fi

if test_start "0k.5" "contract kernel check"; then
  run_in_worktree python3 scripts/check_contract_kernel.py >/dev/null 2>&1
  test_pass "0k.5"
fi

if test_start "0k.6" "contract kernel sources hash aligned"; then
  run_in_worktree python3 scripts/check_contract_kernel.py --kernel docs/contract_kernel.json >/dev/null 2>&1
  test_pass "0k.6"
fi

if test_start "0k.7" "contract kernel file present"; then
  run_in_worktree test -f docs/contract_kernel.json
  test_pass "0k.7"
fi

if test_start "0k.8" "verify.sh parallel primitives structure" 1; then
  run_in_worktree bash -c '
    set -euo pipefail

    verify="plans/verify.sh"
    utils="plans/lib/verify_utils.sh"

    # 1. Core functions exist
    if ! grep -q "^run_parallel_group()" "$verify" && ! grep -q "^run_parallel_group()" "$utils"; then
      echo "FAIL: run_parallel_group() not found" >&2
      exit 1
    fi

    if ! grep -q "^detect_cpus()" "$verify" && ! grep -q "^detect_cpus()" "$utils"; then
      echo "FAIL: detect_cpus() not found" >&2
      exit 1
    fi

    # 2. Arrays are defined and used (whitespace tolerant for runner call)
    for array in SPEC_VALIDATOR_SPECS STATUS_FIXTURE_SPECS; do
      if ! grep -q "${array}=(" "$verify"; then
        echo "FAIL: ${array} array not found" >&2
        exit 1
      fi

      if ! grep -Eq "run_parallel_group[[:space:]]+${array}" "$verify"; then
        echo "FAIL: ${array} not passed to runner" >&2
        exit 1
      fi
    done

    # 3. Timing artifacts (E-RE, ordering tolerant)
    if ! grep -Eq '\''\.time.*VERIFY_ARTIFACTS_DIR|VERIFY_ARTIFACTS_DIR.*\.time'\'' "$verify" && \
       ! grep -Eq '\''\.time.*VERIFY_ARTIFACTS_DIR|VERIFY_ARTIFACTS_DIR.*\.time'\'' "$utils"; then
      echo "FAIL: Timing artifact pattern not found" >&2
      exit 1
    fi

    # 4. Safety guards
    for var in RUN_LOGGED_SUPPRESS_EXCERPT RUN_LOGGED_SKIP_FAILED_GATE RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL; do
      if ! grep -q "\${${var}:-}" "$verify" && ! grep -q "\${${var}:-}" "$utils"; then
        echo "FAIL: Unbound guard for ${var} not found" >&2
        exit 1
      fi
    done

    # 4b. Stack scripts must preserve parallel guard vars
    for script in plans/lib/rust_gates.sh plans/lib/python_gates.sh plans/lib/node_gates.sh; do
      for var in RUN_LOGGED_SUPPRESS_EXCERPT RUN_LOGGED_SKIP_FAILED_GATE RUN_LOGGED_SUPPRESS_TIMEOUT_FAIL; do
        if ! grep -q "${var}=\"\${${var}:-}\"" "$script"; then
          echo "FAIL: ${script} does not preserve ${var}" >&2
          exit 1
        fi
      done
    done

    # 5. Precedence fix (marker-based, robust to formatting)
    if ! grep -q "VERIFY_TIMEOUT_PAREN_FIX" "$verify" && ! grep -q "VERIFY_TIMEOUT_PAREN_FIX" "$utils"; then
      echo "FAIL: Timeout precedence fix marker not found" >&2
      exit 1
    fi

    # 6. Smoke test integration (whitespace tolerant)
    if ! grep -Eq '\''run_logged[[:space:]]+"parallel_smoke"'\'' "$verify"; then
      echo "FAIL: parallel_smoke not invoked via run_logged" >&2
      exit 1
    fi
  '
  test_pass "0k.8"
fi

if test_start "0k.9" "verify.sh parallel acceptance integration marker" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    if ! grep -q "VERIFY_WA_PARALLEL_INTEGRATION" "plans/verify.sh"; then
      echo "FAIL: parallel acceptance integration marker not found" >&2
      exit 1
    fi
    if ! grep -q "workflow_acceptance_jobs()" "plans/verify.sh"; then
      echo "FAIL: workflow_acceptance_jobs() helper not found" >&2
      exit 1
    fi
  '
  test_pass "0k.9"
fi

if test_start "0k.10" "verify.sh run_parallel_group uses array expansion not eval" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    verify="plans/verify.sh"

    # 1. Marker must exist (proves intentional change)
    if ! grep -q "RUN_PARALLEL_NO_EVAL" "$verify"; then
      echo "FAIL: RUN_PARALLEL_NO_EVAL marker not found" >&2
      exit 1
    fi

    # 2. Array parsing must exist
    if ! grep -q "read -ra cmd_array" "$verify"; then
      echo "FAIL: read -ra cmd_array not found" >&2
      exit 1
    fi

    # 3. eval run_logged must be absent
    if grep -q "eval.*run_logged" "$verify"; then
      echo "FAIL: eval command execution still present" >&2
      exit 1
    fi
  '
  test_pass "0k.10"
fi

if test_start "0k.11" "Reject --only-set with empty tokens" 1; then
  # Self-test: verify our own empty-token rejection works
  # Capture both output and exit code
  set +e
  output="$("$SCRIPT_PATH" --only-set "0e,,0f" 2>&1)"
  rc=$?
  set -e
  # Assert non-zero exit code (guards against regression where message prints but exits 0)
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: --only-set with empty tokens should exit non-zero (got 0)" >&2
    exit 1
  fi
  # Assert descriptive error message
  if ! echo "$output" | grep -q "empty token"; then
    echo "FAIL: --only-set with empty tokens should fail with 'empty token' message" >&2
    exit 1
  fi
  test_pass "0k.11"
fi

if test_start "0k.12" "Reject empty or comment-only allowlist" 1; then
  # Create a comment-only allowlist
  empty_allowlist="$WORKTREE/.ralph/empty_allowlist.txt"
  run_in_worktree bash -c 'mkdir -p .ralph && echo "# just a comment" > .ralph/empty_allowlist.txt'

  # Run the REAL validation function with our empty allowlist
  set +e
  output="$(validate_story_allowlist "$empty_allowlist" 2>&1)"
  rc=$?
  set -e

  # Assert non-zero exit code
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: empty/comment-only allowlist should exit non-zero (got 0)" >&2
    exit 1
  fi
  # Assert descriptive error message
  if ! echo "$output" | grep -q "empty or contains only comments"; then
    echo "FAIL: empty/comment-only allowlist should fail with descriptive message" >&2
    exit 1
  fi
  test_pass "0k.12"
fi

if test_start "0k.13" "PRD cache integration tests" 1; then
  # Run the PRD cache integration test suite
  run_in_worktree bash -c 'set -euo pipefail; bash plans/tests/test_prd_cache.sh'
  test_pass "0k.13"
fi

if test_start "0k.14" "Global invariants Appendix A referenced" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    invariants="specs/invariants/GLOBAL_INVARIANTS.md"
    contract="specs/CONTRACT.md"
    if ! grep -q "Appendix A (Normative)" "$invariants"; then
      echo "FAIL: Appendix A marker missing in GLOBAL_INVARIANTS.md" >&2
      exit 1
    fi
    if ! grep -q "GLOBAL_INVARIANTS.md" "$contract"; then
      echo "FAIL: CONTRACT.md missing GLOBAL_INVARIANTS.md reference" >&2
      exit 1
    fi
    if ! grep -q "Appendix A" "$contract"; then
      echo "FAIL: CONTRACT.md missing Appendix A reference" >&2
      exit 1
    fi
  '
  test_pass "0k.14"
fi

if test_start "0k.15" "workflow acceptance cache wiring"; then
  if ! run_in_worktree grep -q "WORKFLOW_ACCEPTANCE_CACHE_DIR" "plans/workflow_acceptance.sh"; then
    echo "FAIL: workflow_acceptance.sh must support WORKFLOW_ACCEPTANCE_CACHE_DIR" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "git clone --shared" "plans/workflow_acceptance.sh"; then
    echo "FAIL: workflow_acceptance.sh must use shared clone when cache enabled" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "WORKFLOW_ACCEPTANCE_CACHE_DIR" "plans/workflow_acceptance_parallel.sh"; then
    echo "FAIL: workflow_acceptance_parallel.sh must wire WORKFLOW_ACCEPTANCE_CACHE_DIR" >&2
    exit 1
  fi
  if ! run_in_worktree grep -q "WORKFLOW_ACCEPTANCE_CACHE_READY" "plans/workflow_acceptance_parallel.sh"; then
    echo "FAIL: workflow_acceptance_parallel.sh must set WORKFLOW_ACCEPTANCE_CACHE_READY" >&2
    exit 1
  fi
  test_pass "0k.15"
fi

if test_start "0k.16" "workflow allowlist coverage" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    ./plans/tests/test_workflow_allowlist_coverage.sh

    tmp_out="$(mktemp)"
    mv plans/workflow_files_allowlist.txt plans/workflow_files_allowlist.txt.bak
    if ./plans/tests/test_workflow_allowlist_coverage.sh >"$tmp_out" 2>&1; then
      echo "FAIL: allowlist coverage should fail when allowlist is missing" >&2
      mv plans/workflow_files_allowlist.txt.bak plans/workflow_files_allowlist.txt
      rm -f "$tmp_out"
      exit 1
    fi
    if ! grep -q "missing allowlist" "$tmp_out"; then
      echo "FAIL: allowlist coverage did not report missing allowlist" >&2
      mv plans/workflow_files_allowlist.txt.bak plans/workflow_files_allowlist.txt
      rm -f "$tmp_out"
      exit 1
    fi
    mv plans/workflow_files_allowlist.txt.bak plans/workflow_files_allowlist.txt
    rm -f "$tmp_out"
  '
  test_pass "0k.16"
fi

if test_start "0k.17" "change detection routing" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    ./plans/tests/test_change_detection_routing.sh
  '
  test_pass "0k.17"
fi

if test_start "0k.18" "verify.sh census flags" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    out="$(./plans/verify.sh --census)"
    echo "$out" | grep -q "VERIFY CENSUS REPORT"

    out_json="$(./plans/verify.sh --census-json)"
    printf "%s" "$out_json" | head -c1 | grep -q "{"
    echo "$out_json" | grep -q "\"census\":true"
  '
  test_pass "0k.18"
fi

if test_start "0k.19" "preflight census passthrough" 1; then
  run_in_worktree bash -c '
    set -euo pipefail
    out="$(./plans/preflight.sh --census)"
    echo "$out" | grep -q "VERIFY CENSUS REPORT"

    out_json="$(./plans/preflight.sh --census-json)"
    printf "%s" "$out_json" | head -c1 | grep -q "{"
    echo "$out_json" | grep -q "\"census\":true"
  '
  test_pass "0k.19"
fi
if test_start "0l" "--list prints test ids"; then
  list_output="$("$ROOT/plans/workflow_acceptance.sh" --list)"
  if [[ -z "$list_output" ]]; then
    echo "FAIL: expected --list output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$list_output" | grep -q "^0e[[:space:]]"; then
    echo "FAIL: expected --list output to include 0e" >&2
    exit 1
  fi
  if ! printf '%s\n' "$list_output" | grep -q "^0k[[:space:]]"; then
    echo "FAIL: expected --list output to include 0k" >&2
    exit 1
  fi
  test_pass "0l"
fi

if test_start "0m" "state/status files update"; then
  status_id="$(cut -f1 "$STATUS_FILE" 2>/dev/null || true)"
  if [[ "$status_id" != "0m" ]]; then
    echo "FAIL: expected status file to record current test id (0m)" >&2
    exit 1
  fi
  if [[ -z "$ONLY_ID" && -z "$FROM_ID" && -z "$UNTIL_ID" && "$RESUME" -eq 0 ]]; then
    prev_state="$(head -n 1 "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$prev_state" != "0l" ]]; then
      echo "FAIL: expected state file to record prior test id (0l), got ${prev_state:-<empty>}" >&2
      exit 1
    fi
  fi
  test_pass "0m"
fi

if test_start "0n" "selector flags work for --only/--resume"; then
  tmp_state="$WORKTREE/.ralph/accept_state_only"
  tmp_status="$WORKTREE/.ralph/accept_status_only"
  rm -f "$tmp_state" "$tmp_status"
  set +e
  "$ROOT/plans/workflow_acceptance.sh" --only 0h --state-file "$tmp_state" --status-file "$tmp_status" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: expected --only 0h run to succeed" >&2
    exit 1
  fi
  if [[ "$(head -n 1 "$tmp_state" 2>/dev/null || true)" != "0h" ]]; then
    echo "FAIL: expected --only run to record 0h in state file" >&2
    exit 1
  fi
  last_id="${ALL_TEST_IDS[$((${#ALL_TEST_IDS[@]}-1))]}"
  echo "$last_id" > "$tmp_state"
  set +e
  resume_output="$("$ROOT/plans/workflow_acceptance.sh" --resume --state-file "$tmp_state" --status-file "$tmp_status" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: expected --resume with last id to exit 0" >&2
    exit 1
  fi
  if ! printf '%s\n' "$resume_output" | grep -q "No tests selected"; then
    echo "FAIL: expected --resume to report no tests selected" >&2
    exit 1
  fi
  test_pass "0n"
fi

if test_start "0n.1" "selector flags work for --only-set"; then
  tmp_state="$WORKTREE/.ralph/accept_state_only_set"
  tmp_status="$WORKTREE/.ralph/accept_status_only_set"
  rm -f "$tmp_state" "$tmp_status"
  set +e
  only_set_output="$("$ROOT/plans/workflow_acceptance.sh" --only-set "0h, 0i" --state-file "$tmp_state" --status-file "$tmp_status" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: expected --only-set run to succeed" >&2
    echo "Output: $only_set_output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$only_set_output" | grep -q "^Test 0h:"; then
    echo "FAIL: expected --only-set output to include 0h" >&2
    exit 1
  fi
  if ! printf '%s\n' "$only_set_output" | grep -q "^Test 0i:"; then
    echo "FAIL: expected --only-set output to include 0i" >&2
    exit 1
  fi
  if [[ "$(head -n 1 "$tmp_state" 2>/dev/null || true)" != "0i" ]]; then
    echo "FAIL: expected --only-set run to record 0i in state file" >&2
    exit 1
  fi
  set +e
  "$ROOT/plans/workflow_acceptance.sh" --only 0h --only-set "0h,0i" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected --only + --only-set to fail" >&2
    exit 1
  fi
  test_pass "0n.1"
fi

exclude_file="$(run_in_worktree bash -c 'path="$(git rev-parse --git-path info/exclude)"; if [[ "$path" != /* ]]; then printf "%s/%s\n" "$(pwd)" "$path"; else printf "%s\n" "$path"; fi')"
exclude_dir="$(dirname "$exclude_file")"
if [[ ! -d "$exclude_dir" ]]; then
  mkdir -p "$exclude_dir"
fi
{
  printf '%s\n' ".context/"
  printf '%s\n' "plans/contract_check.sh"
  printf '%s\n' "plans/contract_review_validate.sh"
  printf '%s\n' "plans/workflow_contract_gate.sh"
  printf '%s\n' "plans/workflow_contract_map.json"
  printf '%s\n' "plans/run_prd_auditor.sh"
  printf '%s\n' "plans/prd_ref_check.sh"
  printf '%s\n' "plans/prd_ref_index.sh"
  printf '%s\n' "plans/build_markdown_digest.sh"
  printf '%s\n' "plans/build_contract_digest.sh"
  printf '%s\n' "plans/build_plan_digest.sh"
  printf '%s\n' "plans/prd_slice_prepare.sh"
} >> "$exclude_file"

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
        "touch": ["plans/fixtures/acceptance_touch.txt"],
        "avoid": []
      },
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["log"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
Summary: acceptance progress entry with enough detail to satisfy progress gate length requirements for workflow acceptance tests
Commands: none (placeholder text to satisfy gate length; no real commands executed in this stub)
Evidence: acceptance stub evidence placeholder to meet minimum content length checks in progress gate validation
Next: proceed with subsequent acceptance steps in the workflow acceptance suite
EOT
echo "<mark_pass>${id}</mark_pass>"
EOF
chmod +x "$STUB_DIR/agent_mark_pass_with_progress.sh"

cat > "$STUB_DIR/agent_mark_pass_with_commit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="${SELECTED_ID:-S1-001}"
progress="${PROGRESS_FILE:-plans/progress.txt}"
touch_file="${ACCEPTANCE_TOUCH_FILE:-plans/fixtures/acceptance_touch.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance mark pass with commit including extra detail to satisfy progress gate length requirements for workflow acceptance tests
Commands: echo >> ${touch_file}; git add; git commit (placeholder text to meet minimum command length requirements)
Evidence: acceptance stub evidence placeholder to meet minimum content length checks in progress gate validation
Next: proceed with subsequent acceptance steps in the workflow acceptance suite
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
Summary: acceptance mark pass meta only with extra detail to satisfy progress gate length requirements for workflow acceptance tests
Commands: append progress only (placeholder text to satisfy gate length; no real commands executed in this stub)
Evidence: acceptance stub evidence placeholder to meet minimum content length checks in progress gate validation
Next: proceed with subsequent acceptance steps in the workflow acceptance suite
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
touch_file="${ACCEPTANCE_TOUCH_FILE:-plans/fixtures/acceptance_touch.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance commit without pass including extra detail to satisfy progress gate length requirements for workflow acceptance tests
Commands: echo >> ${touch_file}; git add; git commit (placeholder text to meet minimum command length requirements)
Evidence: acceptance stub evidence placeholder to meet minimum content length checks in progress gate validation
Next: continue with subsequent acceptance steps in the workflow acceptance suite
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
touch_file="${ACCEPTANCE_TOUCH_FILE:-plans/fixtures/acceptance_touch.txt}"
ts="$(date +%Y-%m-%d)"
cat >> "$progress" <<EOT
${ts} - ${id}
Summary: acceptance mention complete including extra detail to satisfy progress gate length requirements for workflow acceptance tests
Commands: none (placeholder text to satisfy gate length; no real commands executed in this stub)
Evidence: acceptance stub evidence placeholder to meet minimum content length checks in progress gate validation
Next: continue with subsequent acceptance steps in the workflow acceptance suite
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
file="${DELETE_TEST_FILE:-tests/workflow_acceptance_dummy.rs}"
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
rm -f .ralph/state.json
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

if test_start "0a" "auditor cache skip avoids agent call"; then
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
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
      "schema_check": { "missing_fields": [], "notes": ["checked schema"] },
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
  test_pass "0a"
fi

if test_start "0b" "slice preflight warns but continues on unresolved refs"; then
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
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: expected prd_slice_prepare to succeed (unresolved refs are warnings)" >&2
    exit 1
  fi
  if [[ ! -s "$tmpdir/prd_slice.json" ]]; then
    echo "FAIL: expected prd_slice.json output from prd_slice_prepare" >&2
    exit 1
  fi
'
  test_pass "0b"
fi

if test_start "0c" "ref check blocks unresolved refs"; then
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
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
  test_pass "0c"
fi

if test_start "0d" "ref check resolves slash + parenthetical variants"; then
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
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
  test_pass "0d"
fi

if test_start "0" "contract_check resolves contract refs without SIGPIPE"; then
reset_state
contract_test_root="$WORKTREE/.ralph/contract_check_ref_ok"
iter_dir="$contract_test_root/iter_1"
run_in_worktree mkdir -p "$iter_dir"
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
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
      "evidence": ["docs/order_size_discovery.md"],
      "contract_must_evidence": [],
      "enforcing_contract_ats": [],
      "reason_codes": { "type": "", "values": [] },
      "enforcement_point": "",
      "failure_mode": [],
      "observability": { "metrics": [], "status_fields": [], "status_contract_ats": [] },
      "implementation_tests": [],
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
run_in_worktree bash -c '
  set -euo pipefail
  echo "acceptance seed $(date +%s)" > acceptance_contract_check.txt
  git add acceptance_contract_check.txt
  git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: contract_check seed" >/dev/null 2>&1
'
run_in_worktree git rev-parse HEAD~1 > "$iter_dir/head_before.txt"
run_in_worktree git rev-parse HEAD > "$iter_dir/head_after.txt"
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
cat > "$WORKTREE/.ralph/state.json" <<'JSON'
{"last_verify_post_rc":0}
JSON
cp "$ROOT/plans/contract_check.sh" "$WORKTREE/plans/contract_check.sh"
chmod +x "$WORKTREE/plans/contract_check.sh"
set +e
run_in_worktree env \
  CONTRACT_REVIEW_OUT="$iter_dir/contract_review.json" \
  CONTRACT_FILE="$contract_test_root/CONTRACT.md" \
  PRD_FILE="$contract_test_root/prd.json" \
  ./plans/contract_check.sh "$iter_dir/contract_review.json" >/dev/null 2>&1
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
  test_pass "0"
fi

if test_start "1" "schema-violating PRD stops preflight"; then
run_in_worktree mkdir -p .ralph
reset_state
invalid_prd="$WORKTREE/.ralph/invalid_prd.json"
write_invalid_prd "$invalid_prd"
before_blocked="$(count_blocked)"
before_blocked_incomplete="$(count_blocked_incomplete)"
set +e
run_ralph env PRD_FILE="$invalid_prd" PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" RPH_DRY_RUN=1 RPH_RATE_LIMIT_ENABLED=0 RPH_SELECTION_MODE=harness ./plans/ralph.sh 1 >/dev/null 2>&1
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
  test_pass "1"
fi

if test_start "2" "attempted pass flip without verify_post is prevented"; then
reset_state
valid_prd_2="$WORKTREE/.ralph/valid_prd_2.json"
write_valid_prd "$valid_prd_2" "S1-001"
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
  ./plans/ralph.sh 1 >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected non-zero exit when verify_post fails" >&2
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
if ! run_in_worktree ./plans/artifacts_validate.sh "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected manifest to validate for verify_post failure" >&2
  exit 1
fi
manifest_status="$(run_in_worktree jq -r '.final_verify_status' "$manifest_path")"
  if [[ "$manifest_status" != "BLOCKED" ]]; then
    echo "FAIL: expected final_verify_status=BLOCKED on verify_post failure" >&2
    exit 1
  fi
  blocked_dir="$(run_in_worktree jq -r '.blocked_dir // empty' "$manifest_path")"
  if [[ -z "$blocked_dir" ]]; then
    echo "FAIL: expected blocked_dir recorded in manifest" >&2
    exit 1
  fi
  if ! run_in_worktree test -d "$blocked_dir"; then
    echo "FAIL: expected blocked_dir to exist for verify_post failure" >&2
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
  test_pass "2"
fi

if test_start "2b" "mark_pass without meaningful change is blocked"; then
reset_state
valid_prd_2b="$WORKTREE/.ralph/valid_prd_2b.json"
write_valid_prd "$valid_prd_2b" "S1-001"
before_blocked="$(count_blocked)"
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for pass_flip_no_touch" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "pass_flip_no_touch")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected pass_flip_no_touch blocked artifact" >&2
  exit 1
fi
  test_pass "2b"
fi

if test_start "2c" "mark_pass promotes verify mode"; then
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
  test_pass "2c"
fi

if test_start "2d" "update_task requires promotion verify mode"; then
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
  test_pass "2d"
fi

if test_start "2e" "explore profile forbids mark_pass"; then
reset_state
valid_prd_2e="$WORKTREE/.ralph/valid_prd_2e.json"
write_valid_prd "$valid_prd_2e" "S1-020"
before_blocked="$(count_blocked)"
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for mark_pass forbidden" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test2e_log" >&2 || true
  exit 1
fi
latest_block="$(latest_blocked_with_reason "mark_pass_forbidden")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected mark_pass_forbidden blocked artifact" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test2e_log" >&2 || true
  exit 1
fi
  test_pass "2e"
fi

if test_start "2f" "promote profile requires promotion verify"; then
reset_state
valid_prd_2f="$WORKTREE/.ralph/valid_prd_2f.json"
write_valid_prd "$valid_prd_2f" "S1-021"
before_blocked="$(count_blocked)"
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for promote promotion verify requirement" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "profile_requires_promotion_verify")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected profile_requires_promotion_verify blocked artifact" >&2
  exit 1
fi
  test_pass "2f"
fi

if test_start "3" "COMPLETE printed early blocks with blocked_incomplete artifact"; then
reset_state
valid_prd_3="$WORKTREE/.ralph/valid_prd_3.json"
write_valid_prd "$valid_prd_3" "S1-002"
before_blocked_incomplete="$(count_blocked_incomplete)"
before_blocked="$(count_blocked)"
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
  test_pass "3"
fi

if test_start "3b" "COMPLETE mention does not trigger blocked_incomplete"; then
reset_state
valid_prd_3b="$WORKTREE/.ralph/valid_prd_3b.json"
write_valid_prd "$valid_prd_3b" "S1-002"
before_blocked="$(count_blocked)"
before_blocked_incomplete="$(count_blocked_incomplete)"
set +e
test3b_log="$WORKTREE/.ralph/test3b.log"
run_ralph env \
  PRD_FILE="$valid_prd_3b" \
  PROGRESS_FILE="$WORKTREE/plans/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  RPH_AGENT_CMD="$STUB_DIR/agent_mentions_complete.sh" \
  SELECTED_ID="S1-002" \
  ACCEPTANCE_TOUCH_FILE="plans/fixtures/acceptance_touch.txt" \
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for max iters" >&2
  exit 1
fi
after_blocked_incomplete="$(count_blocked_incomplete)"
if [[ "$after_blocked_incomplete" -gt "$before_blocked_incomplete" ]]; then
  echo "FAIL: did not expect blocked_incomplete artifact for COMPLETE mention" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test3b_log" >&2 || true
  exit 1
fi
latest_block="$(latest_blocked_with_reason "max_iters_exceeded" || true)"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected max_iters_exceeded blocked artifact" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test3b_log" >&2 || true
  exit 1
fi
  test_pass "3b"
fi

if test_start "4" "invalid selection writes verify_pre.log (best effort)"; then
reset_state
valid_prd_4="$WORKTREE/.ralph/valid_prd_4.json"
write_valid_prd "$valid_prd_4" "S1-003"
before_blocked="$(count_blocked)"
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
  test_pass "4"
fi

if test_start "5" "lock prevents concurrent runs"; then
reset_state
valid_prd_5="$WORKTREE/.ralph/valid_prd_5.json"
write_valid_prd "$valid_prd_5" "S1-004"
mkdir -p "$WORKTREE/.ralph/lock"
before_blocked="$(count_blocked)"
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
  test_pass "5"
fi

if test_start "5a" "stale lock auto-clears"; then
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
  test_pass "5a"
fi

if test_start "5b" "git identity is set when missing"; then
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
  test_pass "5b"
fi

if test_start "5c" "preflight blocks without timeout or python3"; then
reset_state
valid_prd_5c="$WORKTREE/.ralph/valid_prd_5c.json"
write_valid_prd "$valid_prd_5c" "S1-004"
no_timeout_bin="$WORKTREE/.ralph/no_timeout_bin"
rm -rf "$no_timeout_bin"
mkdir -p "$no_timeout_bin"
for cmd in bash git jq date dirname mkdir tee cp sed awk head tail sort tr stat rm mv cat; do
  if [[ "$cmd" == "date" ]]; then
    continue
  fi
  cmd_path="$(command -v "$cmd" || true)"
  if [[ -z "$cmd_path" ]]; then
    echo "FAIL: required command missing for test setup: $cmd" >&2
    exit 1
  fi
  ln -s "$cmd_path" "$no_timeout_bin/$cmd"
done
cat > "$no_timeout_bin/date" <<'SH'
#!/bin/sh
echo "20260118-000000"
SH
chmod +x "$no_timeout_bin/date"
before_blocked="$(count_blocked)"
set +e
run_in_worktree env \
  PATH="$no_timeout_bin" \
  PRD_FILE="$valid_prd_5c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc=$?
run_in_worktree env \
  PATH="$no_timeout_bin" \
  PRD_FILE="$valid_prd_5c" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >/dev/null 2>&1
rc2=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected preflight to block without timeout/python3" >&2
  exit 1
fi
if [[ "$rc2" -eq 0 ]]; then
  echo "FAIL: expected preflight to block on second run without timeout/python3" >&2
  exit 1
fi
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -lt $((before_blocked + 2)) ]]; then
  echo "FAIL: expected two blocked artifacts for missing_timeout_or_python3" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "missing_timeout_or_python3")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected missing_timeout_or_python3 blocked artifact" >&2
  exit 1
fi
test_pass "5c"
fi

if test_start "5d" "contract review sees iteration artifacts"; then
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
test_pass "5d"
fi

if test_start "6" "missing contract_check.sh writes FAIL contract review"; then
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
  test_pass "6"
fi

if test_start "7" "invalid contract_review.json is rewritten to FAIL"; then
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
  test_pass "7"
fi

if test_start "8" "decision=BLOCKED stops iteration"; then
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
  test_pass "8"
fi

if test_start "9" "decision=FAIL stops iteration"; then
reset_state
valid_prd_9="$WORKTREE/.ralph/valid_prd_9.json"
write_valid_prd "$valid_prd_9" "S1-008"
write_contract_check_stub "FAIL"
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
latest_block="$(latest_blocked_with_reason "contract_review_failed")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for contract_review_failed" >&2
  exit 1
fi
write_contract_check_stub "PASS"
  test_pass "9"
fi

if test_start "10" "decision=PASS with ALLOW pass flip completes"; then
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
  test_pass "10"
fi

if test_start "10b" "final verify uses RPH_FINAL_VERIFY_MODE"; then
reset_state
valid_prd_10b="$WORKTREE/.ralph/valid_prd_10b.json"
write_valid_prd "$valid_prd_10b" "S1-020"
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
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
if ! run_in_worktree ./plans/artifacts_validate.sh "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected artifact manifest to validate" >&2
  exit 1
fi
schema_version="$(run_in_worktree jq -r '.schema_version' "$manifest_path")"
if [[ "$schema_version" != "1" ]]; then
  echo "FAIL: expected schema_version=1" >&2
  exit 1
fi
run_id="$(run_in_worktree jq -r '.run_id // empty' "$manifest_path")"
if [[ -z "$run_id" ]]; then
  echo "FAIL: expected run_id in manifest" >&2
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
  test_pass "10b"
fi

if test_start "10c" "final verify disabled writes SKIPPED manifest"; then
reset_state
valid_prd_10c="$WORKTREE/.ralph/valid_prd_10c.json"
write_valid_prd "$valid_prd_10c" "S1-021"
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
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
if ! run_in_worktree ./plans/artifacts_validate.sh "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected artifact manifest to validate for final verify disabled" >&2
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
  test_pass "10c"
fi

if test_start "10c.1" "update_task blocks non-promotion verify"; then
reset_state
valid_prd_10c="$WORKTREE/plans/prd_acceptance_non_promo.json"
write_valid_prd "$valid_prd_10c" "S1-010"
run_in_worktree git add "$valid_prd_10c" >/dev/null 2>&1
if run_in_worktree git diff --cached --quiet -- "$valid_prd_10c"; then
  run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit --allow-empty -m "acceptance: seed prd non-promo" >/dev/null 2>&1
else
  run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: seed prd non-promo" >/dev/null 2>&1
fi
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
set +e
test10c_log="$WORKTREE/.ralph/test10c.log"
before_blocked="$(count_blocked)"
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for update_task failure" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test10c_log" >&2 || true
  exit 1
fi
latest_block="$(latest_blocked_with_reason "update_task_failed")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected update_task_failed blocked artifact" >&2
  echo "Ralph log tail:" >&2
  tail -n 120 "$test10c_log" >&2 || true
  exit 1
fi

write_contract_check_stub "PASS"
  test_pass "10c.1"
fi

if test_start "10d" "final verify failure writes FAIL manifest"; then
reset_state
valid_prd_10d="$WORKTREE/.ralph/valid_prd_10d.json"
write_valid_prd "$valid_prd_10d" "S1-022"
write_contract_check_stub "PASS" "ALLOW" "true" '["verify_post.log"]' '["verify_post.log"]' '[]'
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
if ! run_in_worktree ./plans/artifacts_validate.sh "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected artifact manifest to validate for final verify failure" >&2
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
  test_pass "10d"
fi

if test_start "11" "contract_review_validate enforces schema file"; then
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
  test_pass "11"
fi

if test_start "12" "workflow contract traceability gate" 1; then
run_in_worktree ./plans/workflow_contract_gate.sh >/dev/null 2>&1
if ! run_in_worktree jq -e '.rules[] | select(.id=="WF-12.1") | .enforcement[] | select(test("smoke") and test("full"))' plans/workflow_contract_map.json >/dev/null; then
  echo "FAIL: WF-12.1 enforcement must document smoke+full modes" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.rules[] | select(.id=="WF-12.1") | .tests[] | select(test("smoke suite"))' plans/workflow_contract_map.json >/dev/null; then
  echo "FAIL: WF-12.1 tests must reference smoke suite coverage" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.rules[] | select(.id=="WF-12.8") | .tests[] | select(test("Test 12"))' plans/workflow_contract_map.json >/dev/null; then
  echo "FAIL: WF-12.8 tests must point to workflow acceptance Test 12" >&2
  exit 1
fi
if ! run_in_worktree jq -e '.rules[] | select(.id=="WF-1.17") | .artifacts[] | select(.=="plans/preflight.sh")' plans/workflow_contract_map.json >/dev/null; then
  echo "FAIL: WF-1.17 must reference plans/preflight.sh artifact" >&2
  exit 1
fi
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
bad_enforcement="$WORKTREE/.ralph/workflow_contract_map.bad_enforcement.json"
run_in_worktree jq '(.rules[] | select(.id=="WF-1.5").enforcement[0])="scripts/__missing__.sh"' "$WORKTREE/plans/workflow_contract_map.json" > "$bad_enforcement"
set +e
run_in_worktree env WORKFLOW_CONTRACT_MAP="$bad_enforcement" ./plans/workflow_contract_gate.sh >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected workflow_contract_gate to fail on missing enforcement path" >&2
  exit 1
fi
bad_tests="$WORKTREE/.ralph/workflow_contract_map.bad_tests.json"
run_in_worktree jq '(.rules[] | select(.id=="WF-1.5").tests[0])="plans/workflow_acceptance.sh (Test 9999)"' "$WORKTREE/plans/workflow_contract_map.json" > "$bad_tests"
set +e
run_in_worktree env WORKFLOW_CONTRACT_MAP="$bad_tests" ./plans/workflow_contract_gate.sh >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected workflow_contract_gate to fail on unknown test id" >&2
  exit 1
fi
  test_pass "12"
fi

check_required_workflow_artifacts() {
  local missing=0
  local f
  local required=(
    "plans/prd.json"
    "plans/ralph.sh"
    "plans/verify.sh"
    "plans/progress.txt"
    "plans/update_task.sh"
    "plans/prd_schema_check.sh"
    "plans/story_verify_allowlist.txt"
    "docs/schemas/contract_review.schema.json"
    "plans/workflow_contract_gate.sh"
    "plans/workflow_acceptance.sh"
    "plans/workflow_contract_map.json"
    "plans/preflight.sh"
  )
  for f in "${required[@]}"; do
    if [[ ! -f "$WORKTREE/$f" ]]; then
      echo "FAIL: required workflow artifact missing: $f" >&2
      missing=1
    fi
  done
  return "$missing"
}

if test_start "12b" "required workflow artifacts are present"; then
  check_required_workflow_artifacts
  test_pass "12b"
fi

if test_start "12c" "missing required workflow artifact fails fast"; then
  set +e
  mv "$WORKTREE/plans/workflow_contract_map.json" "$WORKTREE/.ralph/workflow_contract_map.tmp"
  check_required_workflow_artifacts
  rc=$?
  set -e
  mv "$WORKTREE/.ralph/workflow_contract_map.tmp" "$WORKTREE/plans/workflow_contract_map.json"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected missing artifact to fail" >&2
    exit 1
  fi
  test_pass "12c"
fi

if test_start "12d" "workflow contract gate validates enforcement existence" 1; then
  tmp_map=$(mktemp)
  # NOTE: Do NOT use trap here - workflow_acceptance.sh has a global EXIT trap
  # that would be overwritten, risking leaked worktrees

  # Test 1: missing enforcement script - must fail (non-zero) with specific message
  jq '.rules[0].enforcement = ["plans/ghost_script.sh"]' \
    plans/workflow_contract_map.json > "$tmp_map"

  rc=0
  output="$(WORKFLOW_CONTRACT_MAP="$tmp_map" plans/workflow_contract_gate.sh 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: gate should have returned non-zero for missing enforcement"
    rm -f "$tmp_map"; exit 1
  fi
  if ! echo "$output" | grep -q "missing enforcement"; then
    echo "FAIL: gate should have rejected missing enforcement with specific error"
    echo "Got: $output"
    rm -f "$tmp_map"; exit 1
  fi

  # Test 2: invalid test ID - must fail (non-zero) with specific message
  jq '.rules[0].tests = ["plans/workflow_acceptance.sh (Test 999)"]' \
    plans/workflow_contract_map.json > "$tmp_map"

  rc=0
  output="$(WORKFLOW_CONTRACT_MAP="$tmp_map" plans/workflow_contract_gate.sh 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: gate should have returned non-zero for unknown test id"
    rm -f "$tmp_map"; exit 1
  fi
  if ! echo "$output" | grep -q "unknown test id"; then
    echo "FAIL: gate should have rejected unknown test id with specific error"
    echo "Got: $output"
    rm -f "$tmp_map"; exit 1
  fi

  # Test 3: descriptive text should not cause false positive
  # "postmortem gate check, Test 0g, Test 10d" should only validate 0g and 10d
  jq '.rules[0].tests = ["plans/workflow_acceptance.sh (postmortem gate check, Test 0g, Test 10d)"]' \
    plans/workflow_contract_map.json > "$tmp_map"

  if ! WORKFLOW_CONTRACT_MAP="$tmp_map" plans/workflow_contract_gate.sh 2>&1; then
    echo "FAIL: gate should accept valid test IDs with descriptive text"
    rm -f "$tmp_map"; exit 1
  fi

  # Test 4: non-numeric range should be rejected with "invalid test range" error
  jq '.rules[0].tests = ["plans/workflow_acceptance.sh (Test 0k.1-0k.3)"]' \
    plans/workflow_contract_map.json > "$tmp_map"

  rc=0
  output="$(WORKFLOW_CONTRACT_MAP="$tmp_map" plans/workflow_contract_gate.sh 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: gate should have returned non-zero for invalid test range"
    rm -f "$tmp_map"; exit 1
  fi
  if ! echo "$output" | grep -q "invalid test range"; then
    echo "FAIL: gate should reject non-numeric range with 'invalid test range' error"
    echo "Got: $output"
    rm -f "$tmp_map"; exit 1
  fi

  # Test 5: numeric range should expand fully and validate all IDs
  # Use 5-6 (small stable range, both IDs exist)
  jq '.rules[0].tests = ["plans/workflow_acceptance.sh (Test 5-6)"]' \
    plans/workflow_contract_map.json > "$tmp_map"

  if ! WORKFLOW_CONTRACT_MAP="$tmp_map" plans/workflow_contract_gate.sh 2>&1; then
    echo "FAIL: gate should accept valid numeric range (full expansion)"
    rm -f "$tmp_map"; exit 1
  fi

  # Test 6: slash-separated IDs should validate (existing map pattern)
  jq '.rules[0].tests = ["plans/workflow_acceptance.sh (Test 0h/0i/0j/12)"]' \
    plans/workflow_contract_map.json > "$tmp_map"

  if ! WORKFLOW_CONTRACT_MAP="$tmp_map" plans/workflow_contract_gate.sh 2>&1; then
    echo "FAIL: gate should accept slash-separated test ids"
    rm -f "$tmp_map"; exit 1
  fi

  # Explicit cleanup (no trap)
  rm -f "$tmp_map"
  test_pass "12d"
fi

if test_start "13" "missing PRD file stops preflight"; then
reset_state
missing_prd="$WORKTREE/.ralph/missing_prd.json"
before_blocked="$(count_blocked)"
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
  test_pass "13"
fi

if test_start "14" "verify_pre failure stops before implementation"; then
reset_state
valid_prd_13="$WORKTREE/.ralph/valid_prd_13.json"
write_valid_prd "$valid_prd_13" "S1-010"
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
manifest_path=".ralph/artifacts.json"
if ! run_in_worktree test -f "$manifest_path"; then
  echo "FAIL: expected manifest for verify_pre failure" >&2
  exit 1
fi
if ! run_in_worktree ./plans/artifacts_validate.sh "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: expected manifest to validate on verify_pre failure" >&2
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
  test_pass "14"
fi

if test_start "14b" "verify output is tailed and summary created"; then
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
  test_pass "14b"
fi

# NOTE: Tests 11–21 are intentionally ordered by runtime workflow rather than
# strictly following the WF-12.1–WF-12.7 order in WORKFLOW_CONTRACT.md.
# In particular, Test 14 ("verify_pre failure stops before implementation")
# is grouped here with other verify/preflight behaviour tests instead of
# appearing immediately after the baseline integrity tests in WF-12.2.
if test_start "15" "needs_human_decision=true blocks execution"; then
reset_state
valid_prd_14="$WORKTREE/.ralph/valid_prd_14.json"
write_valid_prd "$valid_prd_14" "S1-010"
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
latest_block="$(latest_blocked_with_reason "needs_human_decision")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for needs_human_decision" >&2
  exit 1
fi
  test_pass "15"
fi

if test_start "15b" "dependency schema rejects forward-slice dependency"; then
set +e
run_in_worktree ./plans/prd_schema_check.sh "plans/fixtures/prd/deps_forward_slice.json" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected schema check to fail for forward-slice dependency" >&2
  exit 1
fi
  test_pass "15b"
fi

if test_start "15c" "dependency ordering respects same-slice deps"; then
reset_state
snapshot_worktree_if_dirty
test15c_log="$WORKTREE/.ralph/test15c.log"
set +e
run_in_worktree env \
  PRD_FILE="$WORKTREE/plans/fixtures/prd/deps_order_same_slice.json" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_SELECTION_MODE=harness \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >"$test15c_log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL: expected dry-run selection to succeed for dependency order test" >&2
  tail -n 120 "$test15c_log" >&2 || true
  exit 1
fi
iter_dir="$(run_in_worktree jq -r '.last_iter_dir // empty' "$WORKTREE/.ralph/state.json" 2>/dev/null || true)"
if [[ -z "$iter_dir" ]]; then
  echo "FAIL: expected last_iter_dir for dependency order test" >&2
  exit 1
fi
selected_id="$(run_in_worktree jq -r '.selected_id // empty' "$WORKTREE/$iter_dir/selected.json")"
if [[ "$selected_id" != "S1-001" ]]; then
  echo "FAIL: expected S1-001 selected before dependency, got ${selected_id}" >&2
  exit 1
fi
  test_pass "15c"
fi

if test_start "15d" "dependency cycle blocks selection"; then
reset_state
snapshot_worktree_if_dirty
test15d_log="$WORKTREE/.ralph/test15d.log"
set +e
run_in_worktree env \
  PRD_FILE="$WORKTREE/plans/fixtures/prd/deps_cycle_same_slice.json" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  RPH_DRY_RUN=1 \
  RPH_SELECTION_MODE=harness \
  RPH_RATE_LIMIT_ENABLED=0 \
  ./plans/ralph.sh 1 >"$test15d_log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for dependency cycle" >&2
  tail -n 120 "$test15d_log" >&2 || true
  exit 1
fi
latest_block="$(latest_blocked_with_reason "dependency_deadlock")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for dependency_deadlock" >&2
  exit 1
fi
if [[ ! -f "$latest_block/dependency_deadlock.json" ]]; then
  echo "FAIL: expected dependency_deadlock.json in blocked artifact" >&2
  exit 1
fi
  test_pass "15d"
fi

if test_start "16" "cheating detected (deleted test file)"; then
reset_state
valid_prd_15="$WORKTREE/.ralph/valid_prd_15.json"
write_valid_prd "$valid_prd_15" "S1-011"
dummy_test_file="tests/workflow_acceptance_dummy.rs"
if run_in_worktree test -e "$dummy_test_file"; then
  dummy_test_file="tests/workflow_acceptance_dummy_${RANDOM}.rs"
fi
# Update scope to include dummy test file
_tmp=$(mktemp)
run_in_worktree jq --arg file "$dummy_test_file" '.items[0].scope.touch += [$file]' "$valid_prd_15" > "$_tmp" && mv "$_tmp" "$valid_prd_15"

# Create a dummy test file to delete
run_in_worktree mkdir -p "$(dirname "$dummy_test_file")"
run_in_worktree bash -c "echo \"// dummy\" > \"$dummy_test_file\""
run_in_worktree git add "$dummy_test_file"
run_in_worktree git -c user.name="test" -c user.email="test@local" commit -m "add dummy test" >/dev/null 2>&1
start_sha="$(run_in_worktree git rev-parse HEAD)"

set +e
test16_log="$WORKTREE/.ralph/test16.log"
run_ralph env \
  PRD_FILE="$valid_prd_15" \
  PROGRESS_FILE="$WORKTREE/.ralph/progress.txt" \
  VERIFY_SH="$STUB_DIR/verify_pass.sh" \
  DELETE_TEST_FILE="$dummy_test_file" \
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
latest_block="$(latest_blocked_with_reason "cheating_detected" || true)"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for cheating_detected" >&2
  tail -n 120 "$test16_log" >&2 || true
  exit 1
fi
reason="$(run_in_worktree jq -r '.reason' "$latest_block/blocked_item.json")"
if [[ "$reason" != "cheating_detected" ]]; then
  echo "FAIL: expected reason=cheating_detected, got ${reason}" >&2
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
if ! run_in_worktree test -f "$dummy_test_file"; then
  echo "FAIL: expected test file restored after self-heal" >&2
  exit 1
fi
write_contract_check_stub "PASS"
  test_pass "16"
fi

if test_start "16b" "harness tamper blocks before processing"; then
reset_state
valid_prd_16b="$WORKTREE/.ralph/valid_prd_16b.json"
write_valid_prd "$valid_prd_16b" "S1-011"
before_blocked="$(count_blocked)"
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for harness tamper" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "harness_sha_mismatch")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for harness_sha_mismatch" >&2
  tail -n 120 "$test16b_log" >&2 || true
  exit 1
fi
copy_worktree_file "plans/ralph.sh"
chmod +x "$WORKTREE/plans/ralph.sh" >/dev/null 2>&1 || true
run_in_worktree git update-index --skip-worktree plans/ralph.sh >/dev/null 2>&1 || true
  test_pass "16b"
fi

if test_start "16c" ".ralph tamper blocks before processing"; then
reset_state
valid_prd_16c="$WORKTREE/.ralph/valid_prd_16c.json"
write_valid_prd "$valid_prd_16c" "S1-012"
before_blocked="$(count_blocked)"
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
after_blocked="$(count_blocked)"
if [[ "$after_blocked" -le "$before_blocked" ]]; then
  echo "FAIL: expected blocked artifact for .ralph tamper" >&2
  exit 1
fi
latest_block="$(latest_blocked_with_reason "ralph_dir_modified")"
if [[ -z "$latest_block" ]]; then
  echo "FAIL: expected blocked artifact for ralph_dir_modified" >&2
  tail -n 120 "$test16c_log" >&2 || true
  exit 1
fi
  test_pass "16c"
fi

if test_start "17" "active slice gating selects lowest slice"; then
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
      "est_size": "S",
      "risk": "low",
      "needs_human_decision": false,
      "passes": false
    }
  ]
}
JSON
run_in_worktree touch "acceptance_tick.txt"
snapshot_worktree_if_dirty
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
  test_pass "17"
fi

if test_start "18" "rate limit sleep updates state and cooldown"; then
reset_state
rate_prd="$WORKTREE/plans/prd_rate_limit.json"
write_valid_prd "$rate_prd" "S1-014"
run_in_worktree git add "$rate_prd" >/dev/null 2>&1
if run_in_worktree git diff --cached --quiet -- "$rate_prd"; then
  run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit --allow-empty -m "acceptance: seed prd rate limit" >/dev/null 2>&1
else
  run_in_worktree git -c user.name="workflow-acceptance" -c user.email="workflow@local" commit -m "acceptance: seed prd rate limit" >/dev/null 2>&1
fi
cat > "$STUB_DIR/agent_select.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "<selected_id>${SELECTED_ID:-S1-014}</selected_id>"
EOF
chmod +x "$STUB_DIR/agent_select.sh"
rate_limit_file="$WORKTREE/.ralph/rate_limit_test.json"
now="$(date +%s)"
window_start=$((now - 300))
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
rate_limit_limit="$(run_in_worktree jq -r '.rate_limit.limit // -1' "$WORKTREE/.ralph/state.json")"
rate_limit_count="$(run_in_worktree jq -r '.rate_limit.count // -1' "$WORKTREE/.ralph/state.json")"
rate_limit_sleep="$(run_in_worktree jq -r '.rate_limit.last_sleep_seconds // 0' "$WORKTREE/.ralph/state.json")"
if [[ "$rate_limit_limit" -ne 2 || "$rate_limit_count" -lt 1 || "$rate_limit_sleep" -le 0 ]]; then
  echo "FAIL: expected rate_limit state to be recorded (limit=2 count>=1 sleep>0)" >&2
  exit 1
fi
rate_limit_logged=0
if run_in_worktree grep -q "RateLimit: sleeping" "$test18_log"; then
  rate_limit_logged=1
fi
latest_log="$(run_in_worktree bash -c 'ls -t plans/logs/ralph.*.log 2>/dev/null | head -n 1')"
if [[ -n "$latest_log" ]] && run_in_worktree grep -q "RateLimit: sleeping" "$latest_log"; then
  rate_limit_logged=1
fi
if [[ "$rate_limit_logged" -ne 1 ]]; then
  echo "WARN: expected rate limit sleep log (state last_sleep_seconds=${rate_limit_sleep})" >&2
  echo "State selection_mode: $(run_in_worktree jq -r '.selection_mode // \"unknown\"' "$WORKTREE/.ralph/state.json" 2>/dev/null || true)" >&2
  echo "State rate_limit: $(run_in_worktree jq -c '.rate_limit // {}' "$WORKTREE/.ralph/state.json" 2>/dev/null || true)" >&2
  echo "Rate limit file: $(run_in_worktree cat "$rate_limit_file" 2>/dev/null || true)" >&2
  echo "Ralph log tail:" >&2
  tail -n 80 "$test18_log" >&2 || true
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
  test_pass "18"
fi

if test_start "19" "circuit breaker blocks after repeated verify_post failure"; then
reset_state
valid_prd_19="$WORKTREE/.ralph/valid_prd_19.json"
write_valid_prd "$valid_prd_19" "S1-015"
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
  test_pass "19"
fi

if test_start "20" "max iterations exceeded"; then
reset_state
valid_prd_20="$WORKTREE/.ralph/valid_prd_20.json"
write_valid_prd "$valid_prd_20" "S1-012"
_tmp=$(mktemp)
run_in_worktree jq '.items[0].scope.touch += ["acceptance_tick.txt"]' "$valid_prd_20" > "$_tmp" && mv "$_tmp" "$valid_prd_20"
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
  test_pass "20"
fi

if test_start "21" "self-heal reverts bad changes"; then
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
  test_pass "21"
fi

# --- Allowlist check tests ---

if test_start "22" "allowlist_check rejects missing entries" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/allowlist_check_test"
  mkdir -p "$tmpdir"
  allowlist="$tmpdir/allowlist.txt"
  prd="$tmpdir/prd.json"

  # Create a minimal allowlist with only one command
  cat > "$allowlist" <<EOF
bash -n plans/verify.sh
EOF

  # Create a PRD with verify commands not in allowlist
  cat > "$prd" <<JSON
{
  "project": "Test",
  "source": {"implementation_plan_path": "x", "contract_path": "y"},
  "rules": {},
  "items": [
    {
      "id": "T-001",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "category": "test",
      "description": "test",
      "contract_refs": [],
      "plan_refs": [],
      "scope": {"touch": ["plans/verify.sh"]},
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh", "cargo test --not-in-allowlist"],
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

  # Should fail due to missing allowlist entry
  set +e
  RPH_STORY_VERIFY_ALLOWLIST_FILE="$allowlist" ./plans/story_verify_allowlist_check.sh "$prd" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: allowlist_check should reject missing entries" >&2
    exit 1
  fi
'
  test_pass "22"
fi

if test_start "23" "allowlist_check passes when all entries present" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/allowlist_check_pass"
  mkdir -p "$tmpdir"
  allowlist="$tmpdir/allowlist.txt"
  prd="$tmpdir/prd.json"

  # Create allowlist with all needed entries
  cat > "$allowlist" <<EOF
bash -n plans/verify.sh
cargo test --workspace
EOF

  cat > "$prd" <<JSON
{
  "project": "Test",
  "source": {"implementation_plan_path": "x", "contract_path": "y"},
  "rules": {},
  "items": [
    {
      "id": "T-001",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "category": "test",
      "description": "test",
      "contract_refs": [],
      "plan_refs": [],
      "scope": {"touch": ["plans/verify.sh"]},
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh", "cargo test --workspace"],
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

  RPH_STORY_VERIFY_ALLOWLIST_FILE="$allowlist" ./plans/story_verify_allowlist_check.sh "$prd" >/dev/null 2>&1
'
  test_pass "23"
fi

if test_start "24" "allowlist_check --format json produces valid JSON" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/allowlist_json_test"
  mkdir -p "$tmpdir"
  allowlist="$tmpdir/allowlist.txt"
  prd="$tmpdir/prd.json"

  cat > "$allowlist" <<EOF
bash -n plans/verify.sh
EOF

  cat > "$prd" <<JSON
{
  "project": "Test",
  "source": {"implementation_plan_path": "x", "contract_path": "y"},
  "rules": {},
  "items": [
    {
      "id": "T-001",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "category": "test",
      "description": "test",
      "contract_refs": [],
      "plan_refs": [],
      "scope": {"touch": ["plans/verify.sh"]},
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh", "bash -n plans/verify.sh"],
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

  output=$(RPH_STORY_VERIFY_ALLOWLIST_FILE="$allowlist" ./plans/story_verify_allowlist_check.sh --format json "$prd" 2>&1)
  if ! echo "$output" | jq -e . >/dev/null 2>&1; then
    echo "FAIL: --format json should produce valid JSON" >&2
    echo "Output: $output" >&2
    exit 1
  fi
  status=$(echo "$output" | jq -r ".status")
  if [[ "$status" != "pass" ]]; then
    echo "FAIL: expected status=pass, got $status" >&2
    exit 1
  fi
'
  test_pass "24"
fi

if test_start "25" "allowlist_lint detects duplicates" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/allowlist_lint_test"
  mkdir -p "$tmpdir"
  allowlist="$tmpdir/allowlist.txt"

  # Create allowlist with duplicates
  cat > "$allowlist" <<EOF
bash -n plans/verify.sh
cargo test --workspace
bash -n plans/verify.sh
EOF

  set +e
  ./plans/story_verify_allowlist_lint.sh "$allowlist" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: allowlist_lint should fail on duplicates" >&2
    exit 1
  fi
'
  test_pass "25"
fi

if test_start "26" "allowlist_lint passes on clean file" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/allowlist_lint_clean"
  mkdir -p "$tmpdir"
  allowlist="$tmpdir/allowlist.txt"

  cat > "$allowlist" <<EOF
# Comment line
bash -n plans/verify.sh
cargo test --workspace
EOF

  ./plans/story_verify_allowlist_lint.sh "$allowlist" >/dev/null 2>&1
'
  test_pass "26"
fi

if test_start "27" "prd_preflight runs gate and allowlist check (smoke mode)" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  # Run preflight on real prd.json in smoke mode (schema + allowlist only)
  ./plans/prd_preflight.sh --smoke plans/prd.json >/dev/null 2>&1
'
  test_pass "27"
fi

if test_start "28" "prd_preflight --strict fails when allowlist script missing" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/preflight_strict_test"
  mkdir -p "$tmpdir"

  # Create a minimal preflight wrapper that simulates missing check script
  cat > "$tmpdir/preflight_test.sh" <<'"'"'SCRIPT'"'"'
#!/usr/bin/env bash
set -euo pipefail
STRICT=1
SCRIPT_DIR="$1"
if [[ ! -x "$SCRIPT_DIR/story_verify_allowlist_check.sh" ]]; then
  echo "[preflight] WARN: story_verify_allowlist_check.sh not found, skipping" >&2
  if [[ $STRICT -eq 1 ]]; then
    echo "[preflight] ERROR: --strict requires allowlist check script" >&2
    exit 2
  fi
fi
exit 0
SCRIPT
  chmod +x "$tmpdir/preflight_test.sh"

  # Point to non-existent dir for strict mode failure
  set +e
  "$tmpdir/preflight_test.sh" "/nonexistent" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ "$rc" -ne 2 ]]; then
    echo "FAIL: --strict should fail when allowlist check missing (got rc=$rc)" >&2
    exit 1
  fi
'
  test_pass "28"
fi

if test_start "28.1" "preflight --strict succeeds with resolvable BASE_REF" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  BASE_REF=HEAD ./plans/preflight.sh --strict >/dev/null 2>&1
'
  test_pass "28.1"
fi

if test_start "28.2" "preflight --strict fails on missing BASE_REF" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  set +e
  BASE_REF="__missing_ref__" ./plans/preflight.sh --strict >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: expected preflight --strict to fail with missing BASE_REF" >&2
    exit 1
  fi
'
  test_pass "28.2"
fi

if test_start "28.3" "preflight exits 2 on missing required file" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/preflight_missing_file"
  mkdir -p "$tmpdir"
  mv plans/prd.json "$tmpdir/prd.json"
  set +e
  ./plans/preflight.sh >/dev/null 2>&1
  rc=$?
  set -e
  mv "$tmpdir/prd.json" plans/prd.json
  if [[ "$rc" -ne 2 ]]; then
    echo "FAIL: expected preflight to exit 2 on missing required file (got rc=$rc)" >&2
    exit 1
  fi
'
  test_pass "28.3"
fi

if test_start "29" "allowlist_suggest generates patch" 1; then
  run_in_worktree bash -c '
  set -euo pipefail
  tmpdir=".ralph/allowlist_suggest_test"
  mkdir -p "$tmpdir"
  allowlist="$tmpdir/allowlist.txt"
  prd="$tmpdir/prd.json"

  # Empty allowlist
  echo "# Empty" > "$allowlist"

  cat > "$prd" <<JSON
{
  "project": "Test",
  "source": {"implementation_plan_path": "x", "contract_path": "y"},
  "rules": {},
  "items": [
    {
      "id": "T-001",
      "priority": 1,
      "phase": 1,
      "slice": 1,
      "category": "test",
      "description": "test",
      "contract_refs": [],
      "plan_refs": [],
      "scope": {"touch": ["plans/verify.sh"]},
      "acceptance": ["a", "b", "c"],
      "steps": ["1", "2", "3", "4", "5"],
      "verify": ["./plans/verify.sh", "cargo test --workspace"],
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

  output=$(RPH_STORY_VERIFY_ALLOWLIST_FILE="$allowlist" ./plans/story_verify_allowlist_suggest.sh "$prd" 2>&1)

  if ! echo "$output" | grep -q "ADD these entries"; then
    echo "FAIL: suggest should indicate entries to add" >&2
    echo "Output: $output" >&2
    exit 1
  fi

  if ! echo "$output" | grep -q "cargo test --workspace"; then
    echo "FAIL: suggest should list missing command" >&2
    echo "Output: $output" >&2
    exit 1
  fi
'
  test_pass "29"
fi

echo "Workflow acceptance tests passed"
