# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Always write `.ralph/artifacts.json` when `verify_post` fails so blocked runs have a validated manifest.
- What value it has (what problem it solves, upgrade provides): Workflow acceptance test 2 can reliably find a manifest on verify_post failure; blocked runs now carry consistent artifacts for triage.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): workflow acceptance test 2 failed with "expected manifest for verify_post failure"; `verify_post` failure path exited before manifest write; acceptance suite blocked `./plans/verify.sh full`.
- Time/token drain it caused: repeated full acceptance runs to reach test 2 failure.
- Workaround I used this PR (exploit): write manifest immediately after `verify_post_failed` block is created.
- Next-agent default behavior (subordinate): if a blocked path is added/changed, ensure manifest creation is explicit and covered by acceptance.
- Permanent fix proposal (elevate): add a helper for blocked-exit paths that always writes the manifest and use it consistently.
- Smallest increment: add one `write_artifact_manifest` call in the verify_post fail branch.
- Validation (proof it got better): CI `./plans/verify.sh full` on clean checkout should pass acceptance test 2; local run skipped per dirty-tree policy.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a small helper for blocked exits to centralize manifest writes; validate by running `./plans/workflow_acceptance.sh --only 2` and full `./plans/verify.sh full` in CI.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require any new blocked-exit path to either call a shared manifest helper or add an acceptance test proving manifest creation.
