# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added fee-aware IOC limit pricer that rejects low net edge and clamps limit prices to the min-edge bound, with unit tests.
- What value it has (what problem it solves, upgrade provides): Prevents market-like IOC limits and guarantees min-edge profitability at the limit price.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Running rustfmt on module files unexpectedly reformatted out-of-scope execution files; scope guard required reverting unrelated diffs.
- Time/token drain it caused: Extra diff review and restores to keep scope clean.
- Workaround I used this PR (exploit): Restored out-of-scope files immediately and avoided broad formatting runs.
- Next-agent default behavior (subordinate): Prefer formatting only the explicitly changed files and check `git status -s` immediately after.
- Permanent fix proposal (elevate): Add a harness check that blocks formatting changes outside scope for PRD iterations.
- Smallest increment: A pre-commit script that diffs scope lists vs. modified files and warns on scope violations.
- Validation (proof it got better): No out-of-scope file changes across successive PRD iterations.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Integrate the pricer into the chokepoint gate ordering (S5-005) and assert order intents use the clamped limit. Smallest increment: wire pricer output into build_order_intent; validate with gate ordering tests and a new integration test asserting limit price propagation.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require a scope diff check after any formatting command; if non-scope files change, revert before continuing.
