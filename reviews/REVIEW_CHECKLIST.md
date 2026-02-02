# PR Review Checklist (No Evidence / No Compounding / No Merge)

## Review Coverage (Required)
- [ ] All modified/added files are enumerated (code + docs + scripts + tests).
- [ ] Each file has a 1-line review note (what changed + risk).
- [ ] New files are intentional and referenced in the review summary.
- [ ] Any validator/contract scripts referenced by a plan are opened and reviewed (source of truth beats plan text).

## Evidence Gate (Required)
- [ ] Proof includes exact commands, 1–3 key output lines, and artifact/log paths.
- [ ] Requirements touched list concrete CR-IDs/contract anchors (no vague claims).
- [ ] If any verification was rerun, the reason is stated.
- [ ] Evidence/compounding/postmortem claims match the actual code (no stale line refs).
- [ ] If workflow/harness files changed, evidence includes `./plans/workflow_verify.sh` during iteration and a final `./plans/verify.sh full` (or CI proof). [WF-VERIFY-EVIDENCE]

## Compounding Gate (Required)
- [ ] "AGENTS.md updates proposed" section contains 1–3 enforceable rules (MUST/SHOULD + Trigger + Prevents + Enforce).
- [ ] "Elevation plan" includes 1 Elevation + 2 subordinate wins, each with Owner + Effort + Expected gain + Proof.
- [ ] The elevation plan directly reduces the Top 3 sinks listed.

## Workflow / Harness Changes (If plans/* or specs/* touched)
- [ ] Workflow file changes add acceptance coverage in `plans/workflow_acceptance.sh` or a gate invoked by it.
- [ ] Smoke/acceptance checks validate real integration (not allowlist-only matches).
- [ ] New gate scripts are added to `plans/verify.sh:is_workflow_file` allowlist.
- [ ] Verify requirement satisfied (local full run or CI) and recorded.

## Drift / Split-brain Check
- [ ] Any coupled artifacts (e.g., workflow contract + map) are updated together and called out.
- [ ] No new duplicate source of truth was introduced without consolidation.

## Claims & Data
- [ ] Performance or integration claims are backed by data or explicitly labeled estimates.
- [ ] Line-number references are avoided or validated; prefer function names/snippets.
- [ ] Schema fields and counts referenced in plans/pseudocode are verified against validator scripts (e.g., `plans/prd_audit_check.sh`).
- [ ] Cache key/dependency scope claims are traced to actual inputs (prompt templates, slice prep, validators, runner scripts).

## Block Conditions
Mark the PR BLOCKED if any are true:
- Evidence section is empty, vague, or missing artifacts.
- Compounding sections (AGENTS.md updates / Elevation plan) are empty or non-enforceable.
- Requirements touched cannot be cited.
