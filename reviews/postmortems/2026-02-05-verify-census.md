# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added `--census` and `--census-json` to `plans/verify.sh` to emit a non-mutating gate census without running tests.
- What value it has (what problem it solves, upgrade provides): Provides fast, safe planning output to understand which gates would run/skip/fail and why.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Needed planning output without executing gates; JSON output had to remain clean (no extra stdout noise).
- Time/token drain it caused: Minor iteration to keep census output non-mutating and deterministic.
- Workaround I used this PR (exploit): Centralized census output in verify.sh and gated info logs during census.
- Next-agent default behavior (subordinate): Keep census output isolated from gate execution and stdout noise.
- Permanent fix proposal (elevate): Add a structured census manifest for workflow acceptance to align with verify census.
- Smallest increment: Keep verify census output schema versioned and strict.
- Validation (proof it got better): Workflow acceptance test 0k.18 verifies census flags and JSON output.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add workflow_acceptance census (metadata-only) and validate via a new 0k.* acceptance test.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response:
  1) MUST keep census output JSON-only on stdout when `--census-json` is set.
  2) MUST avoid running gates or mutating artifacts in census mode.
  3) MUST update workflow acceptance when adding new verify.sh flags.
