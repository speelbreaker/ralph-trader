# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a TLSM state machine with out-of-order event handling and ledger-append interface, plus unit tests for fill-before-ack and convergence.
- What value it has (what problem it solves, upgrade provides): Prevents panics on fill-before-ack, ensures deterministic terminal state, and records each transition for durability.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed to append transitions to the WAL but soldier_core has no infra dependency and scope did not include Cargo.toml; direct use of soldier_infra::Ledger would have violated scope.
- Time/token drain it caused: Required designing a ledger adapter trait and cloning entries for tests instead of direct calls.
- Workaround I used this PR (exploit): Introduced a TlsmLedger trait with TlsmLedgerEntry so core can record transitions without a hard infra dependency.
- Next-agent default behavior (subordinate): When infra types are out-of-scope, add a minimal adapter trait in core and cover with unit tests; defer concrete adapter to the next infra-touching story.
- Permanent fix proposal (elevate): Add a soldier_infra adapter implementation for TlsmLedger with integration tests to prove WAL entries include TLSM transitions.
- Smallest increment: Implement TlsmLedger for soldier_infra::store::ledger::Ledger and add a focused integration test in the infra crate.
- Validation (proof it got better): cargo test -p soldier_core --test test_tlsm plus new integration test asserting WAL lines include TLSM state updates.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire TlsmLedger to soldier_infra::Ledger (smallest increment) and add an integration test that replays the WAL and asserts TLSM transitions are persisted; validate with cargo test -p soldier_infra --test <new test> and full ./plans/verify.sh.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule to document when a story needs an infra adapter but scope excludes Cargo.toml: create a trait boundary in core and record the follow-up adapter in progress/ideas.
