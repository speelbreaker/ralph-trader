# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: preflight now supports `--census` and `--census-json`, passing through to verify census.
- What value it has (what problem it solves, upgrade provides): Enables quick, non-mutating preview of gates without running full verify.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed a fast planning mode without modifying Ralph loop behavior.
- Time/token drain it caused: Minimal; change isolated to preflight + acceptance.
- Workaround I used this PR (exploit): Added passthrough flags and a workflow acceptance check.
- Next-agent default behavior (subordinate): Keep census output non-mutating and JSON-clean.
- Permanent fix proposal (elevate): Consider adding an optional Ralph preflight census hook (opt-in).
- Smallest increment: Maintain preflight passthrough only.
- Validation (proof it got better): Workflow acceptance test 0k.19 covers preflight census.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Optional Ralph hook to emit preflight census before verify; validate by asserting no state mutations.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST update workflow acceptance when adding preflight flags.
  2) MUST keep census output non-mutating.
  3) MUST keep `--census-json` stdout JSON-only.
