# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added a bootstrap-mode exception to verify_pre in the workflow contract, wired enforcement in Ralph, added acceptance coverage for missing-workspace bootstrap behavior, and aligned verify.sh with checkpoint counter support expected by workflow acceptance.
- What value it has (what problem it solves, upgrade provides): Allows safe bootstrap work when the workspace is intentionally missing, without enabling pass flips or relaxing promotion verification, and keeps verify.sh compliant with acceptance expectations.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): verify_pre hard-blocked iterations when Cargo.toml or crates were intentionally absent; no sanctioned path to restore baseline under Ralph.
- Time/token drain it caused: manual work outside the harness and repeated restarts to re-create a workspace before running any story.
- Workaround I used this PR (exploit): Added a contract-defined bootstrap exception with explicit preflight gates and acceptance tests.
- Next-agent default behavior (subordinate): Use RPH_BOOTSTRAP_MODE only when the workspace is missing; otherwise expect verify_pre to run normally.
- Permanent fix proposal (elevate): Add a targeted fixture test that forces a missing workspace and asserts bootstrap preflight order + manifest content.
- Smallest increment: Add a fixture in workflow acceptance that validates bootstrap_preflight cmd ordering.
- Validation (proof it got better): workflow contract gate + workflow acceptance tests cover bootstrap skip and workspace-present behavior.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add an explicit bootstrap section in `plans/ralph.sh` prompt and `docs/skills/ralph-loop-playbook.md` to document when to use it; validate via workflow acceptance text assertions.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require any verify_pre exception to include a contract amendment + acceptance tests in the same PR.
