# Knowledge Index

Use this page to find the authoritative local docs before making or reviewing claims
about framework, vendor, or codebase behavior.

## Contracts and requirements
- `specs/CONTRACT.md` - trading/runtime contract.
- `specs/WORKFLOW_CONTRACT.md` - workflow contract (Ralph loop + harness rules).
- `specs/IMPLEMENTATION_PLAN.md` or `IMPLEMENTATION_PLAN.md` - delivery phases.
- `specs/POLICY.md` - policy constraints and operational rules.
- `specs/SOURCE_OF_TRUTH.md` - canonical ownership of facts.

## Harness and verification
- `plans/ralph.sh` - Ralph orchestrator.
- `plans/verify.sh` - canonical verification gate.
- `plans/workflow_acceptance.sh` - workflow acceptance tests.

## PRD workflow
- `plans/prd.json` - PRD backlog.
- `plans/prd_gate.sh` - PRD gate (schema + lint + refs).
- `plans/prd_audit_check.sh` - audit validator.

## Skills and review protocols
- `SKILLS/` - workflow skills and checklists.
- `reviews/REVIEW_CHECKLIST.md` - required review coverage.

## Codebase maps
- `docs/codebase/` - structure, architecture, integrations, testing.

## Architecture + invariants
- `specs/flows/ARCH_FLOWS.yaml` - system flow map.
- `specs/invariants/GLOBAL_INVARIANTS.md` - global safety invariants (Appendix A: risk gate + state machine).
- `specs/TRACE.yaml` - traceability map.

## Validation references
- `docs/contract_anchors.md` - contract anchor list.
- `docs/validation_rules.md` - validation rule IDs.

## Vendor docs
- `specs/vendor_docs/` - curated vendor/library docs (when present).
- `specs/vendor_docs/deribit.md` - Deribit execution + market data behaviors.

## Review habit
When a claim depends on framework/vendor/codebase behavior, open the source doc
and cite it in the review summary.
