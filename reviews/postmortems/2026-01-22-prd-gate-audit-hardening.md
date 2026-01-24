# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Hardened PRD gating with strict schema, lint, and audit output checks plus fixture-based fault injection tests.
- Contract/plan requirement satisfied: WF-1.15, WF-1.16, WF-3.3, WF-3.5, WF-2.8.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: PRD enforcement could pass with placebo audits and weak deterministic checks.
- Exploit (what I did now): Added a strict gate (schema+lint+refs) and a deterministic audit meta-check to block content-free PASS.
- Subordinate (workflow changes needed): Route all PRD tooling through the strict gate and keep audit output validations mandatory.
- Elevate (permanent fix proposal): Move contract/plan refs to digest-stable anchors and retire fuzzy ref checks.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-1.15, WF-1.16, WF-3.3, WF-3.5, WF-2.8.
- Proof (tests/commands + outputs): `./plans/tests/test_prd_gate.sh` → `test_prd_gate.sh: ok`. `./plans/verify.sh full` → `verify_run_id=20260122_142555`, `postmortem check: no changes detected`, `fatal: could not create directory of '.git/worktrees/workflow_acceptance_9M37Fa': Operation not permitted` (exit 128). Artifacts: `artifacts/verify/20260122_142555`.

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): Fuzzy ref check remains acceptable until digest-anchored refs land -> plans/prd_ref_check.sh + digest tooling -> N.

## 4) Friction Log
- Top 3 time/token sinks:
  1) Aligning schema gates and lint behavior with updated workflow contract requirements.
  2) Updating workflow acceptance fixtures and test harness expectations.
  3) Workflow acceptance worktree creation blocked by permissions during verify.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: `./plans/verify.sh full` fails at workflow acceptance with git worktree create error; fix requires writable `.git/worktrees` (or running in a workspace that permits `git worktree add`); prevention could be a preflight permission check in `plans/workflow_acceptance.sh`.

## 6) Conflict & Change Zoning
- Files/sections changed: PRD gating scripts, workflow contract/map, workflow acceptance/tests, auditor prompt.
- Hot zones discovered: `plans/workflow_acceptance.sh`, `plans/verify.sh`, `specs/WORKFLOW_CONTRACT.md`, `plans/workflow_contract_map.json`.
- What next agent should avoid / coordinate on: Coordinate edits across contract/map pairs to avoid split-brain (updated together here).

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): `plans/prd_gate.sh`, `plans/prd_audit_check.sh`, PRD fixtures under `plans/fixtures/prd/`.
- New "skill" to add/update: None.
- How to apply it (so it compounds): Use `plans/prd_gate.sh` as the single deterministic entrypoint; require `plans/prd_audit_check.sh` post-audit.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST run `plans/prd_gate.sh` (not `plans/prd_lint.sh`) when validating PRDs.
- Trigger: Any PRD validation or PRD tooling change.
- Prevents: Lint-only passes that violate schema/refs requirements.
- Enforce: `plans/prd_gate.sh` + workflow acceptance tests.
2)
- Rule: MUST validate audit output with `plans/prd_audit_check.sh` before caching or accepting audit results.
- Trigger: Running `plans/run_prd_auditor.sh` or consuming `plans/prd_audit.json`.
- Prevents: Placebo PASS audits with empty reasoning.
- Enforce: `plans/run_prd_auditor.sh` and `plans/prd_audit_check.sh`.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Replace fuzzy contract/plan ref checks with digest-stable anchor IDs and enforce ID-based references.
- Owner: Workflow maintainer.
- Effort: M
- Expected gain: Removes ref ambiguity and reduces manual audit time per PRD item.
- Proof of completion: `plans/prd_ref_check.sh` validates IDs against digest index; fixtures cover invalid IDs.

### Subordinate (cheap wins)
1)
- Change: Add a lightweight `plans/tests/test_prd_gate_smoke.sh` that runs schema+lint on a minimal PRD stub for faster local iteration.
- Owner: Workflow maintainer.
- Effort: S
- Expected gain: Reduces local feedback loop for PRD gate tweaks.
- Proof of completion: New test script wired into workflow acceptance smoke mode.

2)
- Change: Add a `plans/prd_gate_help.md` quickstart with env flags and common failure codes.
- Owner: Workflow maintainer.
- Effort: S
- Expected gain: Faster diagnosis when gates fail due to schema/refs mismatches.
- Proof of completion: Doc referenced from `plans/prd_gate.sh` on failure.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): none
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: PRD audits must include concrete notes for PASS and concrete reasons + patch suggestions for FAIL/BLOCKED.
- What is the cheapest automated check that enforces it?: `plans/prd_audit_check.sh` meta-schema validation.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): script
- What would break if we remove your fix?: PRD audits could revert to all-green placebo outputs without detection.
