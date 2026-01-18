# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Made verify change-aware and added workflow acceptance smoke/full modes to separate workflow vs product gates.
- Contract/plan requirement satisfied: WF-5.5, WF-5.5.1, WF-12.7 (specs/WORKFLOW_CONTRACT.md).
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow.
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md.

## 1) Constraint (TOC)
- Constraint encountered: Slow verification for workflow-only edits (tractor vs house).
- Exploit (what I did now): Added change-aware gating and smoke workflow acceptance when only non-workflow files change.
- Subordinate (workflow changes needed): Keep file classifiers and workflow acceptance assertions synced when new stacks or gate rules are added.
- Elevate (permanent fix proposal): Add deterministic workflow_acceptance tests that simulate workflow-only vs runtime-only change sets to validate gate routing.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-5.5, WF-5.5.1, WF-12.7.
- Proof (tests/commands + outputs):
  - Command: ./plans/verify.sh full
    - Key output: "VERIFY OK (mode=full)" and "workflow_acceptance_mode=full"
    - Artifact/log path: artifacts/verify/20260117_180112

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N):
  - File classifiers cover all relevant stack changes -> add simulated change lists in workflow_acceptance -> N
  - BASE_REF fetch works in CI for endpoint gate -> CI run logs -> N

## 4) Friction Log
- Top 3 time/token sinks:
  1) Full workflow_acceptance.sh run in verify.
  2) Full verify.sh execution.
  3) Manual sync across contract/map/acceptance assertions.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None.

## 6) Conflict & Change Zoning
- Files/sections changed: plans/verify.sh; plans/workflow_acceptance.sh; plans/workflow_verify.sh; specs/WORKFLOW_CONTRACT.md; plans/workflow_contract_map.json; AGENTS.md.
- Hot zones discovered: plans/verify.sh gating block; workflow_acceptance.sh verify assertions; WF-5.5 section in specs/WORKFLOW_CONTRACT.md.
- What next agent should avoid / coordinate on: Avoid concurrent edits in plans/verify.sh gating logic and workflow_acceptance assertions without coordination.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): Change-aware gate selectors in plans/verify.sh (is_*_affecting_file + should_run_*).
- New "skill" to add/update: None.
- How to apply it (so it compounds): Reuse classifier helpers for future stack gates.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST update workflow_acceptance assertions when adding change-aware gating in plans/verify.sh.
- Trigger: Adding/modifying should_run_* or workflow acceptance mode logic.
- Prevents: Silent skip of gates or missing policy checks.
- Enforce: plans/workflow_acceptance.sh grep checks.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add acceptance tests that simulate workflow-only vs runtime-only change sets to validate gate routing paths.
- Owner: maintainer
- Effort: M
- Expected gain: Prevent regressions in change-aware gating and reduce repeated full runs.
- Proof of completion: workflow_acceptance.sh includes a deterministic routing test that passes in CI.

### Subordinate (cheap wins)
1)
- Change: Add a helper in workflow_acceptance.sh to set CHANGED_FILES and assert rust/python/node gates skip/run.
- Owner: maintainer
- Effort: S
- Expected gain: Faster validation of change-aware logic.
- Proof of completion: New acceptance check fails when classifiers are removed.

2)
- Change: Document stack classifier patterns in plans/verify.sh header comments.
- Owner: maintainer
- Effort: S
- Expected gain: Fewer accidental misclassifications.
- Proof of completion: Comment block added with classifier patterns.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): N/A
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Verify must be change-aware but fail-closed when detection is unavailable.
- What is the cheapest automated check that enforces it?: workflow_acceptance.sh grep checks for change detection logging and skip messages.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): specs/WORKFLOW_CONTRACT.md + plans/verify.sh.
- What would break if we remove your fix?: Workflow-only edits would unnecessarily run full product stacks, or skip required gates due to missing change detection.
