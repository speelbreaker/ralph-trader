# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added `docs/dispatch_map_discovery.md` documenting current dispatcher mapping logic, tests, contract gaps, and minimal alignment diff.
- What value it has (what problem it solves, upgrade provides): Clarifies current mapping behavior and contract deltas before implementation, reducing rework risk for S1.3 changes.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): PRD contract refs include Anchor-021/VR-024, which are defined in architecture docs rather than `specs/CONTRACT.md`; had to locate them separately and mark out-of-scope.
- Time/token drain it caused: Extra search/validation steps to confirm anchor/VR locations before documenting gaps.
- Workaround I used this PR (exploit): Explicitly called out Anchor-021/VR-024 as status-endpoint requirements and out-of-scope for dispatch mapping.
- Next-agent default behavior (subordinate): When PRD contract refs include Anchor/VR IDs, check `docs/architecture/*` and explicitly mark scope relevance in discovery docs.
- Permanent fix proposal (elevate): Add a lint that validates PRD contract_refs resolve to either `specs/CONTRACT.md` anchors or the architecture Anchor/VR registries and flags missing refs.
- Smallest increment: Extend the existing PRD lint to accept Anchor/VR refs only if present in `docs/architecture/contract_anchors.md` or `docs/architecture/validation_rules.md`.
- Validation (proof it got better): PRD lint fails on unknown Anchor/VR refs and passes once they are documented in the registries.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Implement S1.3 dispatch mapping changes (tolerance-based mismatch, contract_size_usd handling, canonical amount emission) and add AT-277/AT-920 test coverage; validate via `./plans/verify.sh full` with updated dispatch_map tests.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require a contract-ref resolution check in discovery reports when PRD references Anchor-### or VR-### (must note location and scope relevance).
