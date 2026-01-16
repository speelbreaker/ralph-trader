# PR Postmortem (Agent-Filled)

## 0) One-line outcome
- Outcome: Added a PR postmortem questionnaire and enforcement gate, plus new living workflow docs.
- Contract/plan requirement satisfied: specs/WORKFLOW_CONTRACT.md WF-2.8/WF-2.9 (postmortem + enforcement).

## 1) Constraint (TOC)
- Constraint encountered: PR learnings were not captured or enforced.
- Exploit (what I did now): Added a required postmortem template and verify gate.
- Subordinate (workflow changes needed): Update workflow contract and acceptance harness to enforce the gate.
- Elevate (permanent fix proposal): Enforce postmortem presence and recurring-item elevation in verify.

## 2) Evidence & Proof
- Critical MUSTs touched (CR-IDs or contract anchors): WF-2.8, WF-2.9.
- Proof (tests/commands + outputs): ./plans/verify.sh (quick) -> VERIFY OK (mode=quick).

## 3) Guesses / Assumptions
- Assumption -> Where it should be proven -> Validated? (Y/N): Postmortem gate runs in verify (BASE_REF=origin/main) -> plans/postmortem_check.sh -> Y.

## 4) Friction Log
- Top 3 time/token sinks:
  1) Designing a structured, enforceable postmortem format.
  2) Wiring gates into verify + workflow acceptance without breaking harness.
  3) Updating workflow contract map entries.

## 5) Failure modes hit
- Repro steps + fix + prevention check/test: None.

## 6) Conflict & Change Zoning
- Files/sections changed: plans/verify.sh, plans/postmortem_check.sh, specs/WORKFLOW_CONTRACT.md, plans/workflow_contract_map.json, plans/workflow_acceptance.sh, AGENTS.md, WORKFLOW_FRICTION.md, SKILLS/*, reviews/postmortems/*.
- Hot zones discovered: workflow harness + verify gates.
- What next agent should avoid / coordinate on: Keep postmortem gate and workflow contract mapping in sync.

## 7) Reuse
- Patterns/templates created (prompts, scripts, snippets): PR postmortem template + postmortem check script.
- New "skill" to add/update: none.
- How to apply it (so it compounds): Use the template for each PR and keep recurring items tied to enforcement paths.

## 8) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): none
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 9) Apply or it didn't happen
- What new invariant did we just discover?: Every PR must include a structured postmortem entry that is validated by the gate (not just a template mention).
- What is the cheapest automated check that enforces it?: plans/postmortem_check.sh (run via plans/verify.sh).
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): contract.
- What would break if we remove your fix?: PRs could merge without postmortems and recurring issues would not be elevated to enforcement.
