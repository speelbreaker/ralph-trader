# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Updated workflow contract acceptance text to document smoke vs full modes, aligned WF-12.1/WF-12.8 map entries, and added acceptance assertions to keep the map in sync.
- What value it has (what problem it solves, upgrade provides): Prevents traceability gate drift and avoids CI failures from stale map/test references.
- Workstream (Ralph Loop workflow | Stoic Trader bot): Ralph Loop workflow
- Contract used (specs/WORKFLOW_CONTRACT.md | CONTRACT.md): specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): CI failed at workflow acceptance Test 12 with no visible error; traceability gate failed only on PR merge commit; map/test references drifted from acceptance script.
- Time/token drain it caused: Rebase + local repro to identify gate mismatch.
- Workaround I used this PR (exploit): Rebased on main, aligned map text with actual acceptance test IDs, and added acceptance assertions to make the mismatch visible.
- Next-agent default behavior (subordinate): When touching workflow maps or contract text, add/adjust an acceptance assertion for the mapping and run full verify.
- Permanent fix proposal (elevate): Add a dedicated map-to-test alignment check in workflow acceptance to fail with explicit message on drift.
- Smallest increment: Assert WF-12.8 points to Test 12 and WF-12.1 references smoke+full in the map.
- Validation (proof it got better): ./plans/verify.sh full passes with the new acceptance assertions.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add a small helper in workflow_acceptance.sh to validate all WF-* map entries with expected test IDs where the IDs are stable; validate by running ./plans/workflow_acceptance.sh --only 12 and verifying explicit error output on mismatch.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require rebasing onto origin/main before workflow contract/map edits to avoid duplicate WF-* entries and traceability gate failures (enforce by pre-PR checklist or a lightweight script check in workflow acceptance).
