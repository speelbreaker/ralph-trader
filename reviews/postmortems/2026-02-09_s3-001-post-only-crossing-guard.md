# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Post-only preflight guard rejects crossing post_only intents using touch prices, with a rejection counter.
- What value it has (what problem it solves, upgrade provides): Prevents deterministic post-only venue rejects; aligns with AT-916.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): OrderIntent lacked post_only/touch fields; existing preflight only validated order types; scope limited direct edits to preflight.rs.
- Time/token drain it caused: Needed a wrapper API to integrate post-only checks without changing the existing preflight signatures.
- Workaround I used this PR (exploit): Added a post_only guard module and a preflight_intent_with_post_only wrapper in execution/mod.rs.
- Next-agent default behavior (subordinate): Use preflight_intent_with_post_only when post_only and touch data are available.
- Permanent fix proposal (elevate): Extend OrderIntent/preflight.rs to include post_only + touch fields and enforce directly.
- Smallest increment: Add post_only fields to OrderIntent and update preflight.rs + tests.
- Validation (proof it got better): test_post_only_crossing_rejected passes and rejects PostOnlyWouldCross.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire post_only and touch data into OrderIntent/build_order_intent so core preflight enforces without wrappers; validate by adding a build_order_intent test that asserts PostOnlyWouldCross rejection.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a note that new preflight guard inputs should update OrderIntent/preflight.rs unless explicitly scoped otherwise, to avoid wrapper-only enforcement.
