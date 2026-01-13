# ORPHANS_AND_GAPS.md

Priority order: P0 (highest) -> P3 (lowest)

P0 - None detected
- All artifacts listed in specs/WORKFLOW_CONTRACT.md now have a producer/consumer mapping in plans/* or a human/CI actor.
- docs/schemas/contract_review.schema.json is consumed by plans/contract_review_validate.sh.

P2 - Coverage gaps (not orphans, but limited automation)
- Some workflow contract rules rely on human/CI enforcement only (e.g., CI configuration for WF-8.x). These are not disconnected, but lack automated tests.

P3 - Optional artifacts created by humans
- plans/ideas.md and plans/pause.md are optional; plans/init.sh now creates them if missing, but ongoing updates are human/agent-driven.
