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
  1) Nondeterministic tests from shared global counters.
  2) Long workflow acceptance runtime for non-workflow changes.
  3) Rerunning full verify for targeted fixes.

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

## 8) What should we add to AGENTS.md?
1)
- Rule: If specs/WORKFLOW_CONTRACT.md changes, plans/workflow_contract_map.json MUST change in the same PR.
- Trigger: Any edit to specs/WORKFLOW_CONTRACT.md.
- Prevents: Contract/map drift breaking the traceability gate.
- Enforce: plans/verify.sh paired-change check.
2)
- Rule: Tests MUST not depend on shared global state without a reset helper or explicit serialization marker.
- Trigger: Tests that use global counters or shared mutable state.
- Prevents: Cross-test increments causing nondeterministic failures.
- Enforce: Test helper + review checklist.

## 9) Concrete Elevation Plan to reduce Top 3 sinks

### Elevate (permanent fix)
- Change: Replace global AtomicU64 counter with per-test state or a reset helper.
- Owner: workflow
- Effort: M
- Expected gain: Remove serialization and flake risk.
- Proof of completion: Tests pass without serialization; repeated runs stable.

### Subordinate (cheap wins)
1)
- Change: Make workflow_acceptance.sh conditional on workflow file changes.
- Owner: workflow
- Effort: S
- Expected gain: Shorter runs for non-workflow PRs.
- Proof of completion: Acceptance script skips when no workflow diffs and logs reason.

2)
- Change: Add a targeted test-first path for dispatch_map tests before full verify.
- Owner: execution
- Effort: S
- Expected gain: Fewer full reruns for small fixes.
- Proof of completion: Verify logs show targeted tests before full run.

## 10) Enforcement Path (Required if recurring)
- Recurring issue? (Y/N): N
- Enforcement type (script_check | contract_clarification | test | none): none
- Enforcement target (path added/updated in this PR): none
- WORKFLOW_FRICTION.md updated? (Y/N): N

## 11) Apply or it didn't happen
- What new invariant did we just discover?: Postmortems must include AGENTS.md proposals and a concrete elevation plan tied to top sinks.
- What is the cheapest automated check that enforces it?: plans/postmortem_check.sh (run via plans/verify.sh).
- Where is the canonical place this rule belongs? (contract | plan | AGENTS | SKILLS | script): contract
- What would break if we remove your fix?: PRs could merge without compounding changes or enforceable learning.
