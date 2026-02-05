# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Moved PL-10 F1 tooling into Slice 1 as S1-012 and added PRD story to implement f1_certify tooling.
- What value it has (what problem it solves, upgrade provides): Unblocks promotion verification for early slices by making F1_CERT tooling available in Slice 1.
- Governing contract: specs/WORKFLOW_CONTRACT.md (workflow), specs/CONTRACT.md (F1_CERT requirements)

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): S1-008 could not pass because promotion verify requires artifacts/F1_CERT.json, but tooling is defined only in Phase 4.
- Time/token drain it caused: repeated Ralph runs blocked at verify_post with missing F1_CERT.
- Workaround I used this PR (exploit): Moved PL-10 into Slice 1 and added a dedicated S1-012 story in PRD.
- Next-agent default behavior (subordinate): If promotion gating blocks early slices, elevate required tooling into the current slice with plan+PRD updates and acceptance coverage.
- Permanent fix proposal (elevate): Implement f1_certify tooling in S1-012 and remove promotion gate blockers for early slices.
- Smallest increment: Add S1-012 story and plan exception; run workflow acceptance to prove traceability.
- Validation (proof it got better): Workflow acceptance test 0k.19 verifies PRD+plan contain S1-012; verify.sh full passes in this branch.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Implement S1-012 (python/tools/f1_certify.py + wrapper + tests). Validate with ./plans/verify.sh full and a green promotion verify that produces artifacts/F1_CERT.json.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: If promotion verify requires missing tooling, update plan+PRD first; do not attempt to bypass promotion gates.
