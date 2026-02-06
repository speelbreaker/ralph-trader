# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Hardened Ralph loop integrity by reclaiming dead-PID locks immediately, enforcing post-story-verify HEAD/worktree invariants, adding duplicate WF-ID fail-closed checks, and refreshing stale tests/acceptance assertions.
- What value it has (what problem it solves, upgrade provides): Reduces deadlock stalls, prevents unverified mutations after `verify_post`, and prevents workflow contract/map drift from silently passing.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Ralph could wait lock TTL despite owner PID already dead; story-level verify commands could mutate repo state after `verify_post`; duplicated WF IDs were not fail-closed in spec parsing.
- Time/token drain it caused: Extra manual lock cleanup, reruns to diagnose non-deterministic blocked reasons, and delayed detection of contract traceability drift.
- Workaround I used this PR (exploit): Added immediate dead-PID reclaim path, blocked on story-verify HEAD/worktree mutation, tightened `workflow_contract_gate.sh` duplicate detection, and aligned tests with preflight block reasons.
- Next-agent default behavior (subordinate): Treat any post-`verify_post` mutation as a hard block and update workflow acceptance whenever workflow gate semantics tighten.
- Permanent fix proposal (elevate): Add an acceptance scenario that runs a mutating `story.verify` command and asserts deterministic blocked artifact reason + dirty-status capture.
- Smallest increment: Extend `plans/workflow_acceptance.sh` with a focused fixture for `story_verify_dirty_worktree`.
- Validation (proof it got better): `bash ./plans/tests/test_update_task.sh`, `bash ./plans/tests/test_ralph_needs_human.sh`, and `./plans/workflow_contract_gate.sh` all pass with updated assertions.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Best follow-up is a behavior-level acceptance test that exercises post-story-verify mutation and validates the exact blocked artifact fields. Upgrades worth considering: add lock-reclaim telemetry to `.ralph/metrics.jsonl`; enforce WF-ID uniqueness at authoring time with a lightweight pre-commit hook; add a tiny gate test that confirms `extract_ids_all` does not ingest checklist references as definitions.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Add a rule requiring workflow tests to assert blocked `reason` values against current preflight behavior when schema/gate ordering changes; add a rule to include at least one dead-PID lock test when changing lock logic; add a rule that any `WORKFLOW_CONTRACT` ID rename must update both map entries and an acceptance assertion in the same PR.
