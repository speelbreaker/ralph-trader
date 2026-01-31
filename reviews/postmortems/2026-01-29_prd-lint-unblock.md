# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: PRD metadata fixes to unblock Ralph (scope.create/touch alignment, resolvable plan_refs/contract_refs, required observability.metrics) plus story verify allowlist updates, workflow acceptance hardening (duplicate allowlist detection, ralph state tamper stub fix, slice-preflight expectation aligned to warn-not-fail behavior, and a macOS-safe lock fallback in plans/update_task.sh), and the required AGENTS.md Input Guard section.
- What value it has (what problem it solves, upgrade provides): PRD gate and workflow acceptance now pass so Ralph/verify can reach the agent step; avoids false-negative lint/ref failures, allowlist drift, missing AGENTS.md compliance markers, false negatives in ralph tamper detection tests, and mismatched slice-preflight expectations.
- Governing contract: Workflow contract (specs/WORKFLOW_CONTRACT.md).

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): PRD lint failed on existing create paths; PRD ref check failed on non-resolvable P0/P1 refs; workflow acceptance failed on missing allowlist entries, blocking Ralph before agent step.
- Time/token drain it caused: repeated preflight failures and retries; Ralph never reached agent step.
- Workaround I used this PR (exploit): minimally edited PRD entries to reflect current repo state and resolvable refs; added required observability metrics.
- Next-agent default behavior (subordinate): run ./plans/prd_gate.sh early when PRD is touched; fix scope.create vs scope.touch before attempting Ralph.
- Permanent fix proposal (elevate): add a PRD authoring checklist or helper script that enforces scope.create vs scope.touch and validates plan/contract refs at edit time.
- Smallest increment: add a short PRD checklist to AGENTS.md or a small helper in plans/ to validate refs before commit.
- Validation (proof it got better): ./plans/prd_gate.sh passes locally without errors.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Follow-up PR to clean remaining forward-dependency warnings in PRD lint (S4-000, S4-003, S6-002, S6-004, S6-005). Smallest increment: adjust acceptance/steps to remove forward-looking language; validate with ./plans/prd_gate.sh (warnings reduced to 0).

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add an AGENTS.md rule: "If editing plans/prd.json, run ./plans/prd_gate.sh before Ralph; fix scope.create/touch and ref failures before attempting verify." Consider a second rule to require resolvable plan_refs/contract_refs (no placeholder P0/P1 tags).
