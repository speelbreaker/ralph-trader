# PR Review Checklist (No Evidence / No Compounding / No Merge)

## Evidence Gate (Required)
- [ ] Proof includes exact commands, 1–3 key output lines, and artifact/log paths.
- [ ] Requirements touched list concrete CR-IDs/contract anchors (no vague claims).
- [ ] If any verification was rerun, the reason is stated.
- [ ] If workflow/harness files changed, evidence includes `./plans/workflow_verify.sh` during iteration and a final `./plans/verify.sh full` (or CI proof). [WF-VERIFY-EVIDENCE]

## Compounding Gate (Required)
- [ ] "AGENTS.md updates proposed" section contains 1–3 enforceable rules (MUST/SHOULD + Trigger + Prevents + Enforce).
- [ ] "Elevation plan" includes 1 Elevation + 2 subordinate wins, each with Owner + Effort + Expected gain + Proof.
- [ ] The elevation plan directly reduces the Top 3 sinks listed.

## Drift / Split-brain Check
- [ ] Any coupled artifacts (e.g., workflow contract + map) are updated together and called out.
- [ ] No new duplicate source of truth was introduced without consolidation.

## Block Conditions
Mark the PR BLOCKED if any are true:
- Evidence section is empty, vague, or missing artifacts.
- Compounding sections (AGENTS.md updates / Elevation plan) are empty or non-enforceable.
- Requirements touched cannot be cited.
