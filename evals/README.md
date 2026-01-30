# Golden Repro Eval System

Frozen, real failures for evaluating AI coding agents.

## Quick Start

```bash
# Validate a repro is real (bad commit fails, good commit passes)
./evals/run_repro.sh validate preflight-env-var

# Validate all repros
./evals/run_all_repros.sh validate

# Test a patch against a repro
./evals/run_repro.sh apply_patch preflight-env-var my-fix.patch
```

## How It Works

Each repro captures a **real bug** with:

| File | Purpose |
|------|---------|
| `problem.md` | Input to agent (error + expected behavior) |
| `expected_patch.md` | Oracle only (for scoring, NEVER fed to agent) |

The manifest (`repros/manifest.json`) pins:
- **bad_commit**: Full SHA where bug exists
- **good_commit**: Full SHA where bug is fixed
- **validate_cmd**: Command that fails on bad, passes on good
- **verify_cmd**: Regression check after applying patch

## Modes

### `validate` - Prove Repro Is Real

```bash
./evals/run_repro.sh validate <repro-name>
```

1. Checkout bad_commit → validate_cmd **MUST FAIL**
2. Checkout good_commit → validate_cmd **MUST PASS**
3. If either fails, repro is invalid

### `apply_patch` - Test a Fix

```bash
./evals/run_repro.sh apply_patch <repro-name> <patch-file>
```

1. Checkout bad_commit
2. Apply patch + commit
3. Run validate_cmd (proves fix)
4. Run verify_cmd (regression check)
5. Record result to `evals/results/<run-id>/`

## Adding a New Repro

1. Find a real bug with bad/good commits
2. Add entry to `repros/manifest.json`:
   ```json
   {
     "name": "my-bug",
     "branch": "repro/my-bug",
     "bad_commit": "<full-40-char-sha>",
     "good_commit": "<full-40-char-sha>",
     "validate_cmd": "command that fails on bad, passes on good",
     "verify_cmd": "./plans/verify.sh quick",
     "bad_output_regex": "expected|error|pattern",
     "validate_timeout_secs": 30,
     "verify_timeout_secs": 300,
     "category": "lint|validation|logic",
     "difficulty": "easy|medium|hard"
   }
   ```
3. Create branch: `git branch repro/my-bug <bad_commit>`
4. Create `repros/my-bug/problem.md` (agent input)
5. Create `repros/my-bug/expected_patch.md` (oracle)
6. Validate: `./evals/run_repro.sh validate my-bug`

## Design Principles

- **Exit-code semantics**: validate_cmd exit code determines pass/fail (no `|| true`)
- **Full SHAs**: 40-char commit hashes prevent ambiguity
- **Branch pinning**: Harness asserts branch hasn't drifted
- **Oracle separation**: expected_patch.md is for scoring only, never agent input
- **Tool-agnostic**: No agent integration in v1 (just validate + apply_patch)

## Current Repros

| Name | Category | Difficulty |
|------|----------|------------|
| preflight-env-var | lint | easy |
| status-validator-registry | validation | medium |
| prd-lint-refs | lint | easy |
