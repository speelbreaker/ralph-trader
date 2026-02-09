# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Dispatch mismatch rejections now include a deterministic mismatch delta and surface `RejectReason::UnitMismatch`; unit mismatch counter increments on rejection; tests assert mismatch delta.
- What value it has (what problem it solves, upgrade provides): Callers can see the exact contracts-vs-canonical delta for AT-920 rejections, improving debuggability and contract alignment evidence.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Adding `mismatch_delta: Option<f64>` caused a compile error because `DispatchReject` derived `Eq`, which `f64` cannot implement.
- Time/token drain it caused: 1 test rerun after the compile failure.
- Workaround I used this PR (exploit): Removed `Eq` from `DispatchReject` derive.
- Next-agent default behavior (subordinate): Avoid `Eq` derives on structs that include `f64` fields unless a wrapper type is used.
- Permanent fix proposal (elevate): Add a lint note in execution module docs for error types to avoid `Eq` when float fields are present.
- Smallest increment: Update `DispatchReject` derive to `PartialEq` only.
- Validation (proof it got better): `cargo test -p soldier_core --test test_dispatch_map` passes after the change.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Map dispatch mismatch rejections to the contract-level `RejectReasonCode::ContractsAmountMismatch` in the intent response layer; smallest increment is adding the mapping in the response builder with a unit test covering the reason code; validate via targeted tests plus `./plans/verify.sh full`.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: None; this was a one-off compile-time guardrail already enforced by Rust.
