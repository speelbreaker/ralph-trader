# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added gate-ordering constraint test coverage (reject-before-persist, WAL-before-dispatch, WAL-failure blocks dispatch) and documented ordering invariants.
- What value it has (what problem it solves, upgrade provides): Proves CI enforces safety ordering and provides a single doc reference for expected gate sequencing.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Ordering guarantees span multiple outcomes (reject/allow/WAL-fail), so a single happy-path test was insufficient; trace buffers are thread-local and must be drained per scenario.
- Time/token drain it caused: Minor extra iteration to structure multiple subcases safely.
- Workaround I used this PR (exploit): Used fresh observers per subcase and asserted traces/outcomes immediately to avoid cross-case bleed.
- Next-agent default behavior (subordinate): When adding ordering tests, use per-case observers and always drain `take_*` traces.
- Permanent fix proposal (elevate): Add a small test helper for gate ordering assertions in a shared test utils module.
- Smallest increment: Introduce a helper in `crates/soldier_core/tests` that returns a context + asserts trace ordering.
- Validation (proof it got better): Fewer repeated assertions in new tests and no trace-contamination flakes.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a shared helper for gate-ordering assertions; validate by migrating this test to the helper without changing behavior and ensuring `cargo test -p soldier_core --test test_gate_ordering` remains green.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule: "When using `take_gate_sequence_trace`/`take_dispatch_trace`, drain traces per subcase to avoid cross-test bleed." Also add: "Gate-ordering tests must cover reject and WAL-fail paths, not just happy path."
