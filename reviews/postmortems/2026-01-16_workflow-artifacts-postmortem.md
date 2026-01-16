# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added required workflow artifacts to the contract, mapped new WF ids, and enforced presence in workflow acceptance.
- Contract/plan requirement satisfied: WF-1.2 required artifacts list aligned with gates; WF-12.8 traceability kept in sync.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (TOC)
- Constraint encountered: Drift between required artifact docs and gate enforcement.
- Exploit (what I did now): Made required artifacts explicit with new WF ids and added acceptance checks.
- Subordinate (workflow changes needed): Require WF id additions to include workflow_contract_map.json and workflow_acceptance.sh updates.
- Elevate (permanent fix proposal): Automate validation that required artifacts listed in specs/WORKFLOW_CONTRACT.md exist and are mapped.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-1.2, WF-12.8, WF-2.2.
- Proof (tests/commands + outputs):
  - ./plans/verify.sh full
    - VERIFY OK (mode=full)
    - artifacts/verify/20260116_170855

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N):
  - specs/WORKFLOW_CONTRACT.md is canonical -> file header + repo guidance -> Y
  - preflight requires update_task/prd_schema_check -> plans/ralph.sh preflight -> Y
  - verify may update docs/contract_coverage.md -> verify output + user approval -> Y

## 4) Friction Log
- Top 3 time/token sinks:
  1) Full verify run (Rust build/tests).
  2) Keeping WF id list synchronized between contract and map.
  3) Updating workflow acceptance tests without disturbing adjacent fixtures.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None.

## 6) Conflict & Change Zoning
- Files/sections changed: specs/WORKFLOW_CONTRACT.md; plans/workflow_contract_map.json; plans/workflow_acceptance.sh; docs/contract_coverage.md.
- Hot zones discovered: WF-1.x block in specs/WORKFLOW_CONTRACT.md; Test 12 area in plans/workflow_acceptance.sh; WF map block in plans/workflow_contract_map.json.
- What next agent should avoid / coordinate on: Avoid renumbering WF ids; coordinate on Test 12 insertions.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): check_required_workflow_artifacts() acceptance helper.
- New "skill" to add/update: None.
- How to apply it (so it compounds): Reuse the helper when adding new required artifacts.

## 8) What should we add to AGENTS.md?
- Propose 1–3 bullets max.
- Each bullet must be actionable (MUST/SHOULD), local (one rule, one reason), and enforceable (script/test/checklist).
- Include: Trigger condition, failure mode prevented, and where to enforce.
1)
- Rule: MUST update plans/workflow_contract_map.json and plans/workflow_acceptance.sh when adding WF-* rules.
- Trigger: Editing WF lists in specs/WORKFLOW_CONTRACT.md.
- Prevents: WF-12.8 traceability gate failures and undocumented enforcement gaps.
- Enforce: plans/workflow_contract_gate.sh + plans/workflow_acceptance.sh tests.
2)
- Rule: MUST run ./plans/verify.sh full after editing plans/workflow_acceptance.sh.
- Trigger: Any change to workflow acceptance tests.
- Prevents: CI-only acceptance failures.
- Enforce: PR checklist + postmortem proof.
3)
- Rule: SHOULD record generated doc updates from verify (e.g., docs/contract_coverage.md) in the change list.
- Trigger: Running ./plans/verify.sh.
- Prevents: surprise diffs at review time.
- Enforce: PR postmortem + review checklist.

## 9) Concrete Elevation Plan to reduce Top 3 sinks
- Provide 1 Elevation + 2 subordinate cheap wins.
- Each must include Owner, Effort (S/M/L), Expected gain, Proof of completion.
- Must directly reduce the Top 3 sinks listed above.
- Must include one automation (script/check) if possible.

### Elevate (permanent fix)
- Change: Add a script that parses the required artifacts list in specs/WORKFLOW_CONTRACT.md and verifies each artifact exists and has a WF map entry.
- Owner: workflow maintainer
- Effort: M
- Expected gain: Eliminate manual drift between contract and enforcement map.
- Proof of completion: New script run in workflow acceptance; fails on missing artifact or unmapped WF id.

### Subordinate (cheap wins)
1)
- Change: Add a short section to docs/skills/workflow.md about WF id additions requiring map + acceptance updates.
- Owner: workflow maintainer
- Effort: S
- Expected gain: Faster, more consistent WF updates.
- Proof of completion: docs/skills/workflow.md updated with rule.

2)
- Change: Add a PR checklist line to note generated docs after verify.
- Owner: workflow maintainer
- Effort: S
- Expected gain: Fewer review surprises due to generated diffs.
- Proof of completion: .github/pull_request_template.md updated.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): N/A
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Required workflow artifacts must be explicit and enforced.
- What is the cheapest automated check that enforces it?: workflow acceptance tests 12b/12c.
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): contract + workflow acceptance.
- What would break if we remove your fix?: Missing artifacts could cause unexplained gate failures and traceability drift.
