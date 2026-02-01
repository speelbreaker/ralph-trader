# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Postmortem scaffold helper (`plans/scaffold_postmortem.sh`) and PRD gate documentation (`plans/prd_gate_help.md`)
- What value it has (what problem it solves, upgrade provides): Reduces friction for creating postmortem entries (standardized naming, template copy) and provides discoverability for PRD gate failure codes and knobs
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Agents create inconsistently named postmortem files; PRD gate failures lack actionable help
- Time/token drain it caused: Minor — mostly documentation gap, not repeated failures
- Workaround I used this PR (exploit): Implemented the scaffold helper and docs as cheap hygiene
- Next-agent default behavior (subordinate): Run `./plans/scaffold_postmortem.sh <desc>` instead of manually creating postmortem files
- Permanent fix proposal (elevate): Ralph could auto-create postmortem on PR creation (P1 scope)
- Smallest increment: This PR (scaffold + docs)
- Validation (proof it got better): `scaffold_postmortem.sh` creates correctly named files; help pointer appears on prd_gate failures

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response:
  1. [BEST] Add fixture-based test for `MISSING_ANCHOR_REF`/`MISSING_VR_REF` lint codes — proves lint fires, not just that code strings exist. Validate: new test case in `plans/tests/test_prd_lint.sh` that triggers and asserts on these codes.
  2. Auto-invoke scaffold from Ralph on story start (saves one manual step). Validate: Ralph logs show postmortem path created.
  3. Add workflow_contract_gate.sh call to workflow_verify.sh if missing. Validate: `./plans/workflow_verify.sh` fails on contract violations.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1. Already added: "MUST run `./plans/prd_gate.sh` (not `prd_lint.sh`) when validating PRDs"
  2. Already added: "Require `Anchor-###` / `VR-###` IDs when contract_refs mention anchor/VR titles"
  3. No additional rules needed — this was a documentation/tooling PR, not a failure-mode discovery
