# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Implemented OrderSize canonical sizing (option/linear vs perp/inverse), deterministic notional_usd, and a contracts-vs-amount tolerance helper; added targeted unit tests.
- What value it has (what problem it solves, upgrade provides): Prevents unit-mismatch drift by enforcing canonical units for OrderSize and makes notional_usd deterministic; adds a reusable tolerance check to guard contract/amount mismatches.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): `cargo fmt` reformatted an out-of-scope file (`crates/soldier_core/src/venue/cache.rs`), triggering a scope violation risk and extra cleanup.
- Time/token drain it caused: Added a manual revert step and extra verification to keep scope clean.
- Workaround I used this PR (exploit): Manually reverted the out-of-scope formatting change via patch before continuing.
- Next-agent default behavior (subordinate): Prefer formatting only the touched files or delay `cargo fmt` until scope-safe checks are done.
- Permanent fix proposal (elevate): Add a scoped-format helper script (e.g., `scripts/fmt_files.sh`) to format only the files changed in the PRD scope.
- Smallest increment: Document a short “scoped fmt” snippet in `SKILLS/pre-commit.md`.
- Validation (proof it got better): No out-of-scope diffs after formatting; `git status -sb` shows only in-scope files.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire `contracts_amount_matches` into dispatch mapping and emit `Rejected(ContractsAmountMismatch)` with relative tolerance; validate by updating dispatch_map tests and ensuring `cargo test -p soldier_core --test test_dispatch_map` passes.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule to avoid repo-wide formatting when PRD scope excludes directories; prefer file-scoped formatting or manual patches.
