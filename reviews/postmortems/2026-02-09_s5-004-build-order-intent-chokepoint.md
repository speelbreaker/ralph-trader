# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Centralized build_order_intent chokepoint with deterministic gate ordering, phase-1 dispatch auth, RecordedBeforeDispatch trace, and targeted tests.
- What value it has (what problem it solves, upgrade provides): Prevents gate-order drift, blocks OPEN dispatch under degraded risk, and provides a single visible sequencing trace for verification.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Existing build_order_intent signature only returns PreflightReject; needed to add new gates without breaking preflight tests; risk of bypass if preflight module stayed public.
- Time/token drain it caused: Extra iteration to avoid dead_code warnings and keep scope-limited edits.
- Workaround I used this PR (exploit): Added an outcome channel + trace via thread-local context and funneled preflight through the legacy helper.
- Next-agent default behavior (subordinate): Preserve caller signatures by adding explicit outcome/trace channels when refactors must be non-breaking.
- Permanent fix proposal (elevate): Introduce a DispatchIntent type and migrate callers/tests to return a typed gate outcome instead of side-channel state.
- Smallest increment: Add DispatchIntent builder + migrate only new chokepoint tests first.
- Validation (proof it got better): Gate-ordering + dispatch-auth tests pass; verify full green.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Replace thread-local outcome with explicit DispatchIntent (smallest increment), update preflight/gate callers, and validate with existing gate-order tests + full verify.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule to prefer explicit DispatchIntent/result types over thread-local outcome channels, and require a follow-up plan when signature constraints force a side-channel.
