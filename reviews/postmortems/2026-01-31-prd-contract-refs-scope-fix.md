# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: PRD contract_refs updated to include Anchor/VR IDs where applicable; existing paths moved out of scope.create into scope.touch.
- What value it has (what problem it solves, upgrade provides): Restores traceable contract references for coverage checks and fixes PRD scope create/touch validity.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Strict contract coverage checks were at risk of missing IDs due to non-Anchor/VR refs; PRD lint risk from create paths that already exist.
- Time/token drain it caused: Repeated manual diffing across PRD and filesystem to reconcile scope and refs.
- Workaround I used this PR (exploit): Targeted updates to contract_refs and scope blocks to align with coverage and PRD rules.
- Next-agent default behavior (subordinate): Prefer Anchor/VR IDs in contract_refs and validate scope.create paths exist before edits.
- Permanent fix proposal (elevate): Add a PRD lint rule that flags create paths already present on disk and contract_refs lacking Anchor/VR IDs when a matching anchor exists.
- Smallest increment: Extend PRD lint to check create path existence and emit warnings for non-ID contract_refs.
- Validation (proof it got better): PRD lint passes without scope.create violations; contract coverage strict passes.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a PRD lint check for create-path existence (smallest increment) and validate by running ./plans/prd_lint.sh on a fixture that includes an existing path in create.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require contract_refs to include Anchor/VR IDs when referencing contract sections; require scope.create paths to be absent on disk (validated by lint).
