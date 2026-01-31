#!/usr/bin/env bash
# =============================================================================
# Autofix v0 - Deterministic format fixes in isolated worktree
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-quick}"
MAX_ATTEMPTS=3
WORKTREE_DIR="/tmp/autofix_$(date +%s)_$$"

# Trap for worktree cleanup (even on failure/interrupt)
cleanup() {
  local exit_code=$?
  if [[ -d "$WORKTREE_DIR" ]]; then
    echo "Cleaning up worktree: $WORKTREE_DIR" >&2
    cd "$ROOT" 2>/dev/null || true
    git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
  fi
  exit $exit_code
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT"

# Fail-closed: main tree must be clean (no staged/unstaged changes)
# Otherwise git apply + commit could accidentally commit unrelated work
if command -v git >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    echo "ESCALATE: main tree is dirty; commit/stash before running autofix" >&2
    git status --porcelain >&2 || true
    exit 1
  fi
fi

# 1. Create detached worktree (no branch pollution)
git worktree add --detach "$WORKTREE_DIR" HEAD
cd "$WORKTREE_DIR"

# 2. Track base commit for final patch generation
BASE_COMMIT="$(git rev-parse HEAD)"

# 3. Track fixes applied (for final commit message)
fixes_applied=()

# 4. Evidence directory setup
AUTOFIX_RUN_ID="autofix_$(date +%s)_$$"

# Fail-closed: Evidence dir must be gitignored (otherwise "main tree clean" check fails)
if ! git check-ignore -q artifacts/autofix 2>/dev/null; then
  echo "ESCALATE: artifacts/autofix/ not gitignored; add to .gitignore" >&2
  echo "Evidence will be written to /tmp/autofix_evidence/ instead" >&2
  AUTOFIX_EVIDENCE_DIR="/tmp/autofix_evidence/$AUTOFIX_RUN_ID"
else
  AUTOFIX_EVIDENCE_DIR="$ROOT/artifacts/autofix/$AUTOFIX_RUN_ID"
fi
mkdir -p "$AUTOFIX_EVIDENCE_DIR"

# Helper: Run a fix tool with captured output and fail-closed escalation
run_fix() {
  local label="$1"; shift
  local log="$AUTOFIX_EVIDENCE_DIR/${VERIFY_RUN_ID:-unknown}_${label}.log"
  if ! "$@" >"$log" 2>&1; then
    echo "ESCALATE: ${label} failed; see $log" >&2
    tail -n 80 "$log" >&2 || true
    echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/" >&2
    exit 1
  fi
}

# Helper: Fail-closed evidence copy with context
copy_evidence_or_die() {
  local src="$1"
  local dst="$2"
  if ! cp -R "$src" "$dst"; then
    echo "ESCALATE: failed to copy evidence from ${src} to ${dst}" >&2
    echo "Evidence dir: $AUTOFIX_EVIDENCE_DIR" >&2
    exit 1
  fi
}

# 5. Verify loop
passed=0

for attempt in $(seq 1 $MAX_ATTEMPTS); do
  echo "Attempt $attempt/$MAX_ATTEMPTS: Running verify..."

  # Set globally unique VERIFY_RUN_ID (no cross-run collisions)
  VERIFY_RUN_ID="${AUTOFIX_RUN_ID}_attempt${attempt}"
  export VERIFY_RUN_ID

  # Run verify (fail-fast, requires clean worktree)
  if VERIFY_RUN_ID="$VERIFY_RUN_ID" ./plans/verify.sh "$MODE"; then
    echo "✓ All gates passing"
    passed=1

    # Preserve evidence of success
    if [[ -d "artifacts/verify/$VERIFY_RUN_ID" ]]; then
      copy_evidence_or_die "artifacts/verify/$VERIFY_RUN_ID" "$AUTOFIX_EVIDENCE_DIR/"
    fi
    break
  fi

  VERIFY_ARTIFACTS="artifacts/verify/$VERIFY_RUN_ID"

  # CRITICAL: Preserve evidence before worktree cleanup
  # (Otherwise escalation has no debug trail)
  if [[ -d "$VERIFY_ARTIFACTS" ]]; then
    copy_evidence_or_die "$VERIFY_ARTIFACTS" "$AUTOFIX_EVIDENCE_DIR/"
  fi

  # Check for FAILED_GATE (handles pre-run_logged failures)
  if [[ ! -f "$VERIFY_ARTIFACTS/FAILED_GATE" ]]; then
    echo "ESCALATE: Verify failed but no FAILED_GATE found"
    echo "This indicates environment/repo integrity failure (missing tools, dirty tree, etc.)"
    echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/"
    exit 1
  fi

  FAILED_GATE="$(cat "$VERIFY_ARTIFACTS/FAILED_GATE")"
  echo "Failed gate: $FAILED_GATE"

  # Apply deterministic fix
  case "$FAILED_GATE" in
    rust_fmt)
      echo "Applying fix: cargo fmt --all"
      run_fix cargo_fmt cargo fmt --all
      fixes_applied+=("rust_fmt")
      ;;
    python_ruff_format)
      echo "Applying fix: ruff format ."
      run_fix ruff_format ruff format .
      fixes_applied+=("python_ruff_format")
      ;;
    *)
      echo "ESCALATE: Unknown/unsupported gate: $FAILED_GATE"
      echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/"
      exit 1
      ;;
  esac

  # No-op fix detection: tool didn't actually change anything
  if git diff --quiet; then
    echo "ESCALATE: Fix tool ran but produced no changes (non-deterministic failure)"
    echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/"
    exit 1
  fi

  # CRITICAL: Commit in worktree to keep it clean for next verify run
  # (verify.sh fails on dirty worktree unless VERIFY_ALLOW_DIRTY=1, which agents can't use)
  # Use -u (tracked files only), not -A (would commit artifacts/ if ever un-ignored)
  # Disable GPG signing (hangs/fails if user has commit.gpgsign=true)
  git add -u
  git -c commit.gpgsign=false -c user.name=autofix -c user.email=autofix@local \
    commit -m "autofix(wip): $FAILED_GATE"

  # Worktree must be clean after WIP commit (untracked files from formatter caches break verify)
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "ESCALATE: worktree not clean after WIP commit (untracked/modified files remain)" >&2
    git status --porcelain >&2 || true
    echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/" >&2
    exit 1
  fi
done

# 5. Decision: merge or escalate
cd "$ROOT"

if [[ "$passed" == "0" ]]; then
  echo "ESCALATE: Max attempts ($MAX_ATTEMPTS) reached without success"
  echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/"
  exit 1
fi

# 6. Generate COMBINED patch from all WIP commits and apply to main tree
PATCH_FILE="/tmp/autofix_$$.patch"
git -C "$WORKTREE_DIR" diff --binary "$BASE_COMMIT..HEAD" > "$PATCH_FILE"

if [[ ! -s "$PATCH_FILE" ]]; then
  echo "No changes to apply (verify passed without fixes)"
  rm -f "$PATCH_FILE"
  exit 0
fi

# Preserve final patch in evidence dir
copy_evidence_or_die "$PATCH_FILE" "$AUTOFIX_EVIDENCE_DIR/final.patch"

# Fail-closed: Main tree must still be clean before applying patch
# (User could have made changes mid-run even if HEAD didn't drift)
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
  echo "ESCALATE: main tree became dirty during autofix run" >&2
  git status --porcelain >&2 || true
  echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/" >&2
  rm -f "$PATCH_FILE"
  exit 1
fi

# Fail-closed: Check for base drift (main tree HEAD changed during autofix run)
MAIN_HEAD="$(git rev-parse HEAD)"
if [[ "$MAIN_HEAD" != "$BASE_COMMIT" ]]; then
  echo "ESCALATE: Base commit drifted during autofix run"
  echo "  BASE_COMMIT: $BASE_COMMIT"
  echo "  MAIN_HEAD:   $MAIN_HEAD"
  echo "  (User changed branches or pulled during autofix)"
  echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/"
  rm -f "$PATCH_FILE"
  exit 1
fi

# Rollback helper (fail-closed: never leave main tree dirty)
rollback_main_tree() {
  echo "Rolling back main tree to $BASE_COMMIT" >&2
  git reset --hard "$BASE_COMMIT" >/dev/null 2>&1 || true
  git clean -fd >/dev/null 2>&1 || true  # removes untracked but NOT ignored (preserves evidence)
}

# Apply patch to main tree (with rollback on failure)
if ! git apply --index "$PATCH_FILE"; then
  echo "ESCALATE: failed to apply patch to main tree" >&2
  echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/" >&2
  rollback_main_tree
  rm -f "$PATCH_FILE"
  exit 1
fi

# Single commit with summary of all fixes (with rollback on failure)
# Deterministic join (paste -sd can cycle delimiters character-by-character)
# Disable GPG signing (prevents hanging on dev laptops with commit.gpgsign=true)
fix_summary="$(printf '%s\n' "${fixes_applied[@]}" | sort -u | awk 'NR>1{printf(", ")} {printf("%s",$0)} END{print ""}')"
if ! git -c commit.gpgsign=false -c user.name=autofix -c user.email=autofix@local \
  commit -m "autofix: ${fix_summary}"; then
  echo "ESCALATE: failed to commit applied patch" >&2
  echo "Evidence preserved in: $AUTOFIX_EVIDENCE_DIR/" >&2
  rollback_main_tree
  rm -f "$PATCH_FILE"
  exit 1
fi

rm -f "$PATCH_FILE"
echo "✓ Autofix complete: ${fix_summary}"
