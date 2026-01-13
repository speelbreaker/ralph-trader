# FIX_PATCH_PLAN.md

Objective
- Make specs/WORKFLOW_CONTRACT.md and plans/* enforcement 1:1, and add a traceability gate + acceptance coverage for the new rules.

Minimal patch list (applied)
1) specs/WORKFLOW_CONTRACT.md
- Add stable WF-* rule IDs and document previously-enforced gates (scope, allowlist, rate limiting, completion semantics, traceability gate, optional diagnostics).
- Expand WF-5.1 preflight invariants to match plans/ralph.sh (lock, schema check, agent cmd, required scripts, contract/plan inputs).

2) plans/contract_review_validate.sh
- Load docs/schemas/contract_review.schema.json and validate against the schema-derived requirements.

3) plans/workflow_contract_gate.sh + plans/workflow_contract_map.json
- Add a traceability gate that enforces 1:1 coverage of WF-* rule IDs.

4) plans/workflow_acceptance.sh
- Add tests for schema validation, traceability gate, missing PRD, verify_pre failure, needs_human_decision, cheat detection, slice gating, max iters, and self-heal.

5) plans/ralph.sh
- Ensure blocked preflight attempts capture verify_pre.log (best-effort) by defining run_verify/attempt_blocked_verify_pre before block_preflight.

6) plans/init.sh
- Create plans/ideas.md and plans/pause.md if missing; chmod plans/contract_review_validate.sh if present.

How to test (required)
1) ./plans/init.sh
2) ./plans/verify.sh full
3) ./plans/workflow_acceptance.sh
