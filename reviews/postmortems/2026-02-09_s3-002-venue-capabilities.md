# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added venue capabilities + feature flag evaluation for linked/OCO orders, defaulting to fail-closed.
- What value it has (what problem it solves, upgrade provides): Makes linked/OCO support explicitly gated and testable before any preflight wiring.
- Governing contract: specs/CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed to align defaults and flag naming with contract §1.4.4; ambiguity risk around option vs futures gating.
- Time/token drain it caused: Extra contract scan to confirm default/flag semantics.
- Workaround I used this PR (exploit): Implemented a small, explicit capability evaluation helper with default-false feature flag support.
- Next-agent default behavior (subordinate): Re-check §1.4.4 when adding new venue capabilities or wiring preflight configs.
- Permanent fix proposal (elevate): Add a short contract-to-code mapping note in venue/capabilities.rs doc comment with required defaults.
- Smallest increment: Add a 2-3 line comment referencing §1.4.4 and F-08 defaults.
- Validation (proof it got better): Fewer back-and-forths on linked/OCO gating; capability tests stay green.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Wire venue capabilities into the preflight config builder (where intent construction occurs) using FeatureFlags::from_env; validate by expanding preflight tests to assert linked/OCO acceptance only when both flags are set.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require contract section references in new capability modules to prevent silent default drift.
