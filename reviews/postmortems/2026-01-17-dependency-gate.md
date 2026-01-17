# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added dependency-aware eligibility, schema validation for dependencies, and acceptance fixtures/tests.
- Contract/plan requirement satisfied: WF-5.3 selection semantics and WF-12.4 dependency behavior coverage.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow.
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md.

## 1) Constraint (TOC)
- Constraint encountered: Dependency order was not enforced by selection, leading to deadlocks.
- Exploit (what I did now): Added eligibility filter + blocked artifact diagnostics.
- Subordinate (workflow changes needed): Updated acceptance coverage and traceability map.
- Elevate (permanent fix proposal): Enforce dependency integrity in schema + selection gating.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-5.3, WF-12.4, WF-3.5.
- Proof (tests/commands + outputs):
  - ./plans/workflow_contract_gate.sh
    - Output: workflow contract gate: OK
    - Log: /tmp/workflow_contract_gate.log
  - ./plans/workflow_acceptance.sh
    - Output: Workflow acceptance tests passed
    - Log: /tmp/workflow_acceptance.log
  - ./plans/verify.sh full
    - Output: VERIFY OK (mode=full)
    - Log: /tmp/verify_full.log

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N):
  - jq on CI supports map/select/empty constructs -> plans/workflow_acceptance.sh -> N (CI not run)

## 4) Friction Log
- Top 3 time/token sinks:
  1) Threading selection logic through harness without breaking existing gates.
  2) Updating acceptance overlays for new fixture paths.
  3) Keeping traceability map in sync with new acceptance tests.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None.

## 6) Conflict & Change Zoning
- Files/sections changed: specs/WORKFLOW_CONTRACT.md; plans/ralph.sh; plans/prd_schema_check.sh; plans/workflow_acceptance.sh; plans/workflow_contract_map.json; plans/fixtures/prd/*.json.
- Hot zones discovered: plans/ralph.sh selection block; plans/workflow_acceptance.sh test ordering.
- What next agent should avoid / coordinate on: Avoid parallel edits to selection/acceptance sections without coordinating.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): None.
- New "skill" to add/update: None.
- How to apply it (so it compounds): N/A.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST add new fixture paths to plans/workflow_acceptance.sh overlays when introducing new workflow fixtures.
- Trigger: Adding files under plans/fixtures/** referenced by workflow acceptance.
- Prevents: Acceptance tests running against stale fixtures.
- Enforce: plans/workflow_acceptance.sh overlay list review.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add a workflow acceptance self-check that fails if fixture files referenced in tests are missing from overlays.
- Owner: workflow
- Effort: S
- Expected gain: Prevent silent acceptance drift.
- Proof of completion: workflow_acceptance.sh fails on missing overlay fixture.

### Subordinate (cheap wins)
1)
- Change: Document dependency eligibility block reasons in specs/WORKFLOW_CONTRACT.md.
- Owner: workflow
- Effort: S
- Expected gain: Faster diagnosis.
- Proof of completion: updated contract text.

2)
- Change: Add a short helper in acceptance to build dependency fixtures for ad hoc tests.
- Owner: workflow
- Effort: S
- Expected gain: Faster test setup.
- Proof of completion: helper used in at least one test.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): N/A
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Dependency eligibility must gate selection in both modes.
- What is the cheapest automated check that enforces it?: workflow acceptance tests for dependency ordering/deadlock.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): contract + acceptance script.
- What would break if we remove your fix?: Ralph could select stories out of dependency order and deadlock silently.
