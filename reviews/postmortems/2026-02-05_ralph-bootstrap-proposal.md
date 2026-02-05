# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a workflow proposal for a bootstrap mode in `plans/proposals/2026-02-05_bootstrap_ralph_baseline.md` and logged it in `plans/ideas.md`.
- What value it has (what problem it solves, upgrade provides): Captures a concrete, fail-closed design to unblock Ralph iterations when the workspace is intentionally missing, without relaxing promotion-grade verify.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): The verify preflight blocks any iteration when the Rust workspace is missing; bootstrap scaffolding cannot start.
- Time/token drain it caused: Manual back-and-forth on how to handle baseline verification in bootstrapping scenarios.
- Workaround I used this PR (exploit): Documented a bootstrap profile proposal and guardrails rather than changing behavior immediately.
- Next-agent default behavior (subordinate): If a similar need arises, start by drafting a proposal with explicit fail-closed gates and tests.
- Permanent fix proposal (elevate): Implement the bootstrap profile with acceptance tests as outlined in the proposal.
- Smallest increment: Add workflow acceptance tests that simulate missing `Cargo.toml` and verify `mark_pass` is forbidden.
- Validation (proof it got better): Proposal is now captured and discoverable; future work can reference it.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Implement bootstrap profile + tests as specified in the proposal; validate via `./plans/verify.sh` and workflow acceptance tests.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: If baseline verification prevents bootstrap work, require a written proposal before adding bypasses.
