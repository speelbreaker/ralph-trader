# SKILL: /ralph-loop (Run Ralph Harness Iterations)

Purpose
- Execute the Ralph harness for autonomous PRD story implementation
- Handle preflight checks and profile selection
- Monitor progress and interpret results
- Follow contract-first, fail-closed workflow

When to use
- Implementing multiple PRD stories from plans/prd.json
- Autonomous iteration through a slice
- Testing workflow changes with ralph execution
- Batch implementation with verification gates

## Prerequisites

### Before First Run
```bash
# One-time scaffolding (if not done)
./plans/bootstrap.sh

# Get runnable baseline
./plans/init.sh

# Validate baseline is green
./plans/verify.sh full
```

### Preflight Checks
- [ ] `plans/prd.json` exists and has `passes=false` stories
- [ ] Current slice is well-defined in `IMPLEMENTATION_PLAN.md`
- [ ] Baseline verify is green
- [ ] No ralph lock exists (`.ralph/lock/`)
- [ ] Git working tree is clean (required; Ralph blocks dirty trees)

## Profile Selection

Choose profile based on intent:

| Profile | Use Case | Verify Mode | Timeout | Notes |
|---------|----------|-------------|---------|-------|
| `fast` | Rapid iteration, exploration | quick | 20min | Good for development |
| `thorough` | Production-quality work | full | 1hr | Recommended default |
| `audit` | Review existing work | full | default (0 unless overridden) | No self-heal |
| `verify` | Verification-only (no code) | full | default | Uses cheap model |
| `explore` | Exploration (no pass marks) | quick | default | Forbids marking passes |
| `promote` | Final promotion to done | promotion | default | All gates required |

## Workflow

### 1) Set Up Environment (Optional)
```bash
# Export profile presets
source plans/profile.sh thorough

# Or set vars manually
export RPH_PROFILE=thorough
export RPH_AGENT_CMD=claude
export RPH_AGENT_MODEL=sonnet
```

### 2) Run Ralph
```bash
# Standard thorough run (10 iterations)
RPH_PROFILE=thorough ./plans/ralph.sh 10

# Fast exploration (5 iterations)
RPH_PROFILE=fast ./plans/ralph.sh 5

# Single iteration for testing
./plans/ralph.sh 1

# With specific model for critical work
RPH_PROFILE=thorough RPH_AGENT_MODEL=opus ./plans/ralph.sh 3
```

### 3) Monitor Progress

**During execution:**
```bash
# Watch progress log
tail -f plans/progress.txt

# Watch current iteration log
tail -f plans/logs/ralph.*.log

# Check ralph state
cat .ralph/state.json | jq .
```

**Key state fields:**
- `iteration`: Current iteration number
- `active_slice`: Lowest slice with any `passes=false`
- `selected_id`: Story being worked
- `last_failure_streak`: Consecutive verify_post failures (for circuit breaker)

### 4) Interpret Results

**Success indicators:**
- Iteration completes with `outcome=pass`
- Story marked `passes=true` in prd.json
- Commit created with story changes
- Progress entry appended

**Failure modes:**
| Outcome | Meaning | Next Steps |
|---------|---------|------------|
| `BLOCKED_*` | Preflight failure | Fix the blocking condition |
| `VERIFY_FAILED` | Tests failed | Review verify log in `.ralph/iter_N_*/verify_post.log` |
| `CONTRACT_CONFLICT` | Contract violation | Review contract review in `.ralph/iter_N_*/contract_review_*.json` |
| `SCOPE_VIOLATION` | Out-of-scope edit | Fix scope in prd.json or revert edit |
| `TIMEOUT` | Iteration timeout | Increase timeout or simplify story |
| `CIRCUIT_BREAKER` | Repeated failures | Human intervention needed |

### 5) Review Artifacts

After ralph completes:
```bash
# Check final state
cat .ralph/state.json | jq .

# Review artifact manifest
cat .ralph/artifacts.json | jq .

# Check updated PRD
cat plans/prd.json | jq '.items[] | select(.passes==true) | .id'

# Review progress entries
tail -50 plans/progress.txt

# Examine iteration artifacts
ls -la .ralph/iter_*/
```

## Common Patterns

### Pattern 1: Implement Current Slice
```bash
# Run until slice is complete or circuit breaker trips
RPH_PROFILE=thorough ./plans/ralph.sh 20
```

### Pattern 2: Test Single Story
```bash
# Ensure only one story has passes=false in current slice
./plans/ralph.sh 1

# Review results
cat .ralph/iter_1_*/selected_item.json
cat .ralph/iter_1_*/verify_post.log
```

### Pattern 3: Verify-Only Pass (Promotion)
```bash
# Verify existing work and flip passes if green
RPH_PROFILE=promote ./plans/ralph.sh 10
```

### Pattern 4: Recovery from Circuit Breaker
```bash
# 1. Check what failed repeatedly
cat .ralph/state.json | jq '.circuit_breaker'

# 2. Fix the issue manually (or update PRD scope)
# ...

# 3. Clear circuit breaker state
rm .ralph/state.json

# 4. Resume
./plans/ralph.sh 10
```

## Rerun/Recovery (Focused)

Use this when a run is stuck, timed out, or blocked by stale state.

### 1) Quick Diagnosis
```bash
ps -ef | rg -i "plans/ralph.sh|workflow_acceptance|verify.sh"
ls -la .ralph/lock && cat .ralph/lock/lock.json
ls -1t plans/logs | head -3
ls -1dt .ralph/iter_* | head -3
```

### 2) Clean Up Stale Runs
```bash
# Kill orphaned workflow_acceptance workers (only in this repo)
pgrep -f "workflow_acceptance" | xargs -I{} sh -c 'cwd=$(lsof -p {} 2>/dev/null | awk '/ cwd /{print $NF; exit}'); case "$cwd" in "'$PWD'"* ) kill {} ;; esac'

# Remove stale lock
rm -rf .ralph/lock

# Optional: remove corrupted acceptance dirs
rm -rf .ralph/workflow_acceptance_*
```

### 3) Timeout-Safe Rerun (Recommended)
Use a detached run so long verify steps aren’t killed by CLI/tool timeouts.
```bash
nohup env RPH_ITER_TIMEOUT_SECS=0 WORKFLOW_ACCEPTANCE_TIMEOUT=90m ./plans/ralph.sh 1 \
  > plans/logs/ralph.nohup.$(date +%Y%m%d-%H%M%S).log 2>&1 &
```

### 4) Quick-Verify Iterations (Speed)
Use quick verify during iteration; pass-flip still uses promotion verify.
```bash
RPH_VERIFY_MODE=quick ./plans/ralph.sh 1
```

Checkpoint rollout controls for local quick verify:
```bash
# Default safety posture
VERIFY_CHECKPOINT_ROLLOUT=off

# Evaluate skip eligibility without granting skip authority
VERIFY_CHECKPOINT_ROLLOUT=dry_run

# Enforce path (requires explicit kill switch token)
VERIFY_CHECKPOINT_ROLLOUT=enforce VERIFY_CHECKPOINT_KILL_SWITCH="ks-$(openssl rand -hex 8)"
```

Checkpoint telemetry and guard defaults:
```bash
# Staleness + forced-run guardrails
VERIFY_CHECKPOINT_MAX_AGE_SECS=86400
VERIFY_CHECKPOINT_MAX_CONSEC_SKIPS=10
VERIFY_CHECKPOINT_FORCE_AFTER_SECS=21600

# Hash phase target/budget for checkpoint logic (500ms target, 2.0s hard ceiling)
VERIFY_CHECKPOINT_HASH_TARGET_MS=500
VERIFY_CHECKPOINT_HASH_BUDGET_MS=2000

# Telemetry retention (default mode-aware TTL: dry_run=30d, enforce=7d)
VERIFY_CHECKPOINT_TELEMETRY_MAX_FILES=200
VERIFY_CHECKPOINT_TELEMETRY_MAX_BYTES=20971520
VERIFY_CHECKPOINT_TELEMETRY_TTL_DAYS=<override_optional>
```

If checkpoint state becomes corrupt or lock handling wedges:
```bash
./plans/reset_verify_checkpoint.sh
./plans/verify.sh quick
```

### 5) Pass-Touch Gate Reminder
If only meta files changed (e.g., `plans/progress.txt`), pass-flip is blocked.
Ensure at least one scope-touch change before printing `<mark_pass>`.

### 6) Post-Failure Where-To-Look
```bash
ls -1dt .ralph/blocked_* | head -1
cat .ralph/blocked_*/verify_summary.txt
tail -n 80 .ralph/blocked_*/verify_pre.log
ls -la .ralph/iter_*/verify_post.log
```

### 7) Do-Not-Do
- Do not edit `plans/prd.json` manually during a Ralph run.
- Do not run multiple Ralph loops concurrently.
- Do not use `VERIFY_ALLOW_DIRTY=1` without explicit owner approval.

## Safety Guardrails

**Ralph enforces:**
- Single concurrent run (lock file)
- Scope gating (only touch allowed paths)
- Contract alignment review (mandatory)
- Cheat detection (blocks test deletion)
- Circuit breaker (auto-halt on repeated failure)

**Never:**
- Edit prd.json directly during a Ralph iteration (pass flips are handled by `plans/update_task.sh`)
- Edit verify.sh without `RPH_ALLOW_VERIFY_SH_EDIT=1`
- Edit ralph.sh during ralph execution
- Disable verification gates

## Troubleshooting

### Ralph won't start
```bash
# Check for lock
ls -la .ralph/lock/

# Remove stale lock if no ralph process running
rm -rf .ralph/lock/

# Check PRD validity
./plans/prd_schema_check.sh plans/prd.json
```

### Iteration keeps timing out
```bash
# Increase timeout
RPH_ITER_TIMEOUT_SECS=7200 ./plans/ralph.sh 5

# Or simplify story scope
# (edit prd.json to make story smaller)
```

### Verify fails but locally it passes
```bash
# Check if dirty worktree issue
git status

# Ralph may need clean tree for reliable verify
git stash
./plans/verify.sh full
```

### Contract review fails
```bash
# Read the review
cat .ralph/iter_N_*/contract_review_*.json | jq .

# Check alignment with CONTRACT.md
grep -A 10 "section_id" .ralph/iter_N_*/contract_review_*.json
```

## Integration with Other Skills

**Before ralph:**
- `/interview` - Build detailed specs for PRD stories
- `/verify` - Ensure baseline is green

**During ralph:**
- Progress monitoring (tail logs)
- MCP ralph tools for inspection

**After ralph:**
- `/pr-review` - Review ralph commits before PR
- `/post_pr_postmortem` - Document changes

## Output Expectations

**On success:**
- One or more stories marked `passes=true`
- Git commits for each successful story
- Progress entries in `plans/progress.txt`
- Artifact manifest in `.ralph/artifacts.json`

**On failure:**
- Clear failure reason in state.json
- Iteration artifacts with logs
- Progress entry documenting failure
- Circuit breaker state if repeated failure

## Advanced Configuration

```bash
# Dry run (no actual execution)
RPH_DRY_RUN=1 ./plans/ralph.sh 1

# Custom verify mode
RPH_VERIFY_MODE=quick ./plans/ralph.sh 5

# Allow agent to edit PRD (legacy, not recommended)
RPH_ALLOW_AGENT_PRD_EDIT=1 ./plans/ralph.sh 5

# Rate limiting
RPH_RATE_LIMIT_PER_HOUR=50 ./plans/ralph.sh 10

# Different agent
RPH_AGENT_CMD=codex RPH_AGENT_MODEL=gpt-5.2-codex ./plans/ralph.sh 5
```

## Contract Alignment

This skill implements:
- [WF-2.1] Contract alignment mandatory
- [WF-2.2] Verification mandatory
- [WF-2.3] WIP=1 enforcement
- [WF-2.4] Slice order enforcement
- [WF-2.5] No cheating detection

See `specs/WORKFLOW_CONTRACT.md` for full workflow contract.
