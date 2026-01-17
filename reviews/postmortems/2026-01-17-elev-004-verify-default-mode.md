# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Default verify mode now infers full in CI and quick locally when no arg is provided; workflow acceptance asserts the behavior.
- Contract/plan requirement satisfied: CI-grade verification must run via plans/verify.sh (mode handling aligned with CI usage).
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: Verify default behavior contradicted the CI-grade-by-default intent, risking under-testing and rework.
- Exploit (what I did now): Implemented CI-aware default mode inference and added a workflow acceptance assertion to pin it.
- Subordinate (workflow changes needed): Always add/adjust workflow acceptance checks when changing verify defaults or mode parsing.
- Elevate (permanent fix proposal): Keep the CI-aware default in verify.sh and enforce it via workflow acceptance (implemented here).

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-5.5 (verify gates), WF-12.1 (workflow acceptance coverage)
- Proof (tests/commands + outputs): ./plans/verify.sh full (see artifacts/verify/20260117_075230/)
  - ./plans/verify.sh full
    - VERIFY_SH_SHA=53f3f0c4e1a9cc61a45b7fcff35559befd437d332b80d212a8862448e1fefbe9
    - mode=full verify_mode=none root=/Users/admin/conductor/workspaces/ralph/yangon
    - Workflow acceptance tests passed
    - Artifacts: artifacts/verify/20260117_075230/

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): CI sets CI=1; no CI job relies on implicit quick mode -> CI workflow config -> N

## 4) Friction Log
- Top 3 time/token sinks:
  1) Full workflow acceptance run inside verify
  2) Full Rust test suite in verify full
  3) Manual confirmation of verify default behavior prior to change

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None

## 6) Conflict & Change Zoning
- Files/sections changed: plans/verify.sh (mode parsing), plans/workflow_acceptance.sh (new assertion), reviews/postmortems/2026-01-17-elev-004-verify-default-mode.md
- Hot zones discovered: plans/verify.sh mode/VERIFY_MODE block; workflow acceptance verify guard section
- What next agent should avoid / coordinate on: Coordinate any verify mode/default changes with workflow acceptance assertions.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): None
- New "skill" to add/update: None
- How to apply it (so it compounds): N/A

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST update workflow acceptance when changing verify.sh mode defaults.
- Trigger: Any edit to plans/verify.sh mode parsing or defaults.
- Prevents: CI under-testing due to silent default drift.
- Enforce: plans/workflow_acceptance.sh assertion.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add/keep workflow acceptance assertion that verifies CI-aware default mode in plans/verify.sh.
- Owner: Workflow maintainers
- Effort: S
- Expected gain: Avoid rework from CI under-testing; faster detection of default-mode drift.
- Proof of completion: workflow_acceptance.sh contains CI-default assertion; verify full passes with it.

### Subordinate (cheap wins)
1)
- Change: Document default mode behavior in verify.sh header (already updated).
- Owner: Workflow maintainers
- Effort: S
- Expected gain: Reduce manual re-checks of default behavior.
- Proof of completion: verify.sh header includes CI-aware default note.

2)
- Change: Add an AGENTS.md bullet for verify default changes and acceptance check.
- Owner: Workflow maintainers
- Effort: S
- Expected gain: Prevent regressions via checklist enforcement.
- Proof of completion: AGENTS.md includes new rule with enforcement path.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): test
- Enforcement target (path added/updated in this PR): plans/workflow_acceptance.sh
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Verify default mode must match CI-grade expectations when no args are provided.
- What is the cheapest automated check that enforces it?: Workflow acceptance assertion on verify.sh mode parsing.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): script
- What would break if we remove your fix?: CI could silently run quick mode by default, reducing coverage.
