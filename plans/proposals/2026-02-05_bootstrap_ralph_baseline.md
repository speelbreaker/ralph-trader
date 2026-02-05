# Workflow Change Proposal: Bootstrap Mode for Ralph Baseline-Green Constraint

Date: 2026-02-05
Owner: (unassigned)

## Summary
Allow a **strict, fail-closed bootstrap mode** for Ralph when the Rust workspace is intentionally missing, without weakening promotion-grade verification or allowing pass flips. This enables “from-scratch” scaffolding work while preserving the contract requirement that **passes=true only occurs after a green, promotion-grade verify**.

## Problem
Ralph always runs `verify_pre` and blocks if the baseline is not green. If a workflow requires removing or rebuilding the Rust workspace (e.g., scratch re-implementation comparisons), `verify_pre` cannot pass because `cargo` gates fail without `Cargo.toml` and crates. This blocks any bootstrap work, even when the first story’s purpose is to restore a valid workspace.

## Constraints (Must Not Change)
- **WF-2.2**: Verification is mandatory; passes=true only after verify green.
- **WF-2.3**: WIP=1 and one commit per iteration.
- **Fail-closed default**: no silent skips or weakening gates.

## Proposal
Introduce a **bootstrap-only mode** that:

1. **Skips `verify_pre` ONLY when the workspace is missing** (e.g., no `Cargo.toml`), and **records a blocked/skipped reason** in the iteration artifacts.
2. **Forbids mark_pass** in bootstrap mode (equivalent to `RPH_FORBID_MARK_PASS=1`).
3. Requires a **minimal preflight gate** in place of `verify_pre`:
   - `./plans/preflight.sh --strict`
   - `./plans/prd_gate.sh`
   - `./plans/run_prd_auditor.sh`
   - `./plans/prd_audit_check.sh`
4. **Retains `verify_post` unchanged** (must be `full` or `promotion` depending on profile), and **still blocks pass flips** until a promotion-grade verify passes on a valid workspace.

### Suggested Implementation Sketch
- New profile: `bootstrap` (in `plans/ralph.sh`)
  - `RPH_FORBID_MARK_PASS=1`
  - `RPH_REQUIRE_MARK_PASS=0`
  - `RPH_VERIFY_MODE=full` (verify_post still runs when workspace exists)
  - `RPH_ALLOW_MISSING_BASELINE=1`
- In `verify_pre` step, if `RPH_ALLOW_MISSING_BASELINE=1` **and** a missing-workspace sentinel is detected (e.g., `Cargo.toml` missing), then:
  - Run the minimal preflight gate set
  - Record a `verify_pre_skipped_bootstrap` reason in the iter artifacts
  - Continue to agent step without claiming baseline green
- Guardrails:
  - If the workspace is **present**, `verify_pre` must run normally.
  - If the agent attempts `<mark_pass>`, block with an explicit `BLOCKED_MARK_PASS_FORBIDDEN` outcome.

## Acceptance Test Updates (Required)
- Add a workflow acceptance test that:
  - Removes/renames `Cargo.toml` in a fixture worktree
  - Runs Ralph with `RPH_PROFILE=bootstrap`
  - Asserts `verify_pre` is skipped with a clear reason and that `mark_pass` is forbidden
  - Asserts no pass flips occur
- Add a negative test that:
  - Uses bootstrap mode with workspace **present**
  - Asserts `verify_pre` runs normally (no skip)

## Risks
- Misuse could allow iterations to proceed without a green baseline.
  - Mitigation: strict gating, explicit bootstrap profile, and mark_pass forbidden.
- Confusion over allowed scope in bootstrap stories.
  - Mitigation: add a short bootstrap section to `plans/ralph.sh` output and update `docs/skills/ralph-loop-playbook.md`.

## Non-Goals
- This does **not** relax promotion verification.
- This does **not** allow passes=true without full/promotion verify.
- This does **not** permit bypassing scope or contract review gates.

## Rollout Plan (If Approved)
1. Implement profile + guardrails in `plans/ralph.sh`.
2. Update `plans/workflow_acceptance.sh` with bootstrap tests.
3. Run `./plans/verify.sh full` on a clean tree (or rely on CI). If local verify fails due to dirty tree, follow dirty worktree policy.
4. Update `docs/skills/ralph-loop-playbook.md` with a “bootstrap mode” entry.

