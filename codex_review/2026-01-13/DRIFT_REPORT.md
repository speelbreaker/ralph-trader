# DRIFT_REPORT.md

Summary
- Status: ALIGNMENT ACHIEVED after patches below.
- All WF-* rules in specs/WORKFLOW_CONTRACT.md are mapped in plans/workflow_contract_map.json and validated by plans/workflow_contract_gate.sh.

Drift findings (before patch) and resolution

1) Missing rule IDs in specs/WORKFLOW_CONTRACT.md
- Drift: Spec had no stable WF-* identifiers, preventing traceability.
- Fix: Added WF-* IDs across all sections and acceptance checklist items.

2) Contract review schema not enforced by code
- Drift: specs/WORKFLOW_CONTRACT.md §7 required docs/schemas/contract_review.schema.json, but plans/contract_review_validate.sh ignored it.
- Fix: plans/contract_review_validate.sh now loads docs/schemas/contract_review.schema.json and validates against it.

3) Enforcements present in code but undocumented in spec
- Drift: plans/ralph.sh enforced scope_gate, story verify allowlist, rate limiting/circuit breaker, lock gating, and additional preflight invariants; plans/verify.sh enforced endpoint/CI gate source checks; spec lacked explicit rules.
- Fix: Added WF-5.7, WF-5.10, WF-5.11, WF-5.5.1, WF-8.5, and expanded WF-5.1 preflight invariants (lock, schema check, agent cmd, required scripts, contract/plan inputs).

4) Blocked artifacts verify_pre.log best-effort for preflight failures
- Drift: Spec required verify_pre.log best-effort for blocked cases; preflight blocks did not attempt verify_pre.
- Fix: block_preflight now calls attempt_blocked_verify_pre; run_verify is defined before preflight.

5) No drift gate to ensure WF-* mapping coverage
- Drift: No enforcement verifying WF-* rule coverage.
- Fix: Added plans/workflow_contract_map.json + plans/workflow_contract_gate.sh; integrated into workflow acceptance tests (WF-12.8).

6) Acceptance tests missing required checklist coverage
- Drift: workflow_acceptance.sh did not cover contract_review_validate schema enforcement, traceability gate, missing PRD, verify_pre failure, needs_human_decision, cheat detection, active slice gating, max_iters, or self-heal.
- Fix: Added Tests 10–18 and stubs to cover these cases.

7) Optional workflow logs not created by init
- Drift: plans/ideas.md and plans/pause.md were recommended but not created by plans/init.sh.
- Fix: plans/init.sh now creates plans/ideas.md and plans/pause.md if missing; also chmods plans/contract_review_validate.sh if present.

Residual notes
- Rules relying on human process/CI remain labeled “manual” in the traceability map (e.g., WF-0.1, WF-4.1, WF-8.1, WF-8.4).
- Some preflight invariants (missing verify.sh/update_task.sh/contract/plan) are enforced by code but not yet covered by acceptance tests; manual verification remains.
