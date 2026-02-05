# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a minimal note to the OrderSize discovery report clarifying deferral of wiring OrderSize into the dispatch path until sizing invariants are enforced.
- What value it has (what problem it solves, upgrade provides): Makes the minimal-diff plan explicit and avoids premature wiring that would violate sizing invariants.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Story required append-only edits to docs/order_size_discovery.md; change size limited to 1-3 lines; full verify required even for a doc-only change.
- Time/token drain it caused: Full verify added several minutes of runtime to a 1-line doc update.
- Workaround I used this PR (exploit): Ran targeted checks (file exists + rg) before full verify to keep feedback tight.
- Next-agent default behavior (subordinate): Keep doc-only edits minimal, run targeted checks first, then full verify.
- Permanent fix proposal (elevate): Add a doc-only fast path in verify.sh for discovery docs while still enforcing preflight + postmortem.
- Smallest increment: Allow a change-detection rule for docs/order_size_discovery.md to run preflight + postmortem only.
- Validation (proof it got better): Verify runtime for doc-only edits drops to under 60s without reducing required gates.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Follow-up should implement contract-aligned OrderSize validation (try_new + tolerance checks) and only then wire build_order_intent; smallest increment is adding try_new plus AT-277/AT-920 wrapper tests; validate by passing those wrappers in verify.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule: doc-only, append-only stories should still run targeted checks first, but must run full verify before pass.
