# PR Review Checklist (No Evidence / No Compounding / No Merge)

## Review Coverage (Required)
- [ ] All modified/added files are enumerated (code + docs + scripts + tests).
- [ ] Each file has a 1-line review note (what changed + risk).
- [ ] New files are intentional and referenced in the review summary.
- [ ] Skills consulted are listed (SKILLS/*) or explicitly marked "none".
- [ ] Any validator/contract scripts referenced by a plan are opened and reviewed (source of truth beats plan text).
- [ ] Concurrency check: identify shared files written without locks (cache/logs/artifacts) and assess multi-process risks.
- [ ] Aggregation/merge check: verify expected inputs are complete (e.g., all slices present) and missing inputs are fail-closed.
- [ ] Cache trust boundary: validate cache schema/path safety; cached paths must be constrained to repo.
- [ ] Platform assumptions: check for macOS bash incompatibilities (e.g., wait -n) or GNU-only tools.

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

## Architectural Risk Lens (Required)
- [ ] Architectural-level failure modes: at least 1 architecture-level failure mode is documented with trigger + blast radius + detection signal; if none, reviewer writes "none" with explicit rationale.
- [ ] Systemic risks and emergent behaviors: at least 1 cross-component/system interaction risk is documented with trigger + propagation path + containment; if none, reviewer writes "none" with explicit rationale.
- [ ] Compounding failure scenarios: at least 1 chained scenario (A -> B -> C) is documented with breakpoints that stop escalation; if none, reviewer writes "none" with explicit rationale.
- [ ] Hidden assumptions that could be violated: assumptions (ordering/timing/env/data/contracts) are listed with how violation is detected and handled; if none, reviewer writes "none" with explicit rationale.
- [ ] Long-term maintenance hazards: at least 1 maintainability hazard (complexity/ownership/test brittleness/operational toil) is documented with mitigation owner + smallest follow-up; if none, reviewer writes "none" with explicit rationale.

## Workflow / Harness Changes (If plans/* or specs/* touched)
- [ ] Workflow file changes add acceptance coverage in `plans/workflow_acceptance.sh` or a gate invoked by it.
- [ ] Smoke/acceptance checks validate real integration (not allowlist-only matches).
- [ ] New gate scripts are added to `plans/verify.sh:is_workflow_file` allowlist.
- [ ] Verify requirement satisfied (local full run or CI) and recorded.

## High-ROI Enforcement Map (Workflow)
- [ ] Workflow contract/map edits: run `./plans/workflow_contract_gate.sh` and update mapping assertions. Enforcement: script + acceptance. Tests: 12.
- [ ] PRD edits: run `./plans/prd_gate.sh` + `./plans/prd_audit_check.sh`. Enforcement: script + acceptance. Tests: 0k.1/0k.2/27.
- [ ] Change-detection helper edits in `plans/verify.sh`: update acceptance assertions. Enforcement: acceptance. Tests: 0k.
- [ ] Blocked-exit/manifest behavior changes: ensure manifest written. Enforcement: acceptance. Tests: 0g/10c/10d.
- [ ] New/tightened workflow validation rules: acceptance must call real validator path and assert non-zero + specific error. Enforcement: doc-only until test added. Tests: none.

## Drift / Split-brain Check
- [ ] Any coupled artifacts (e.g., workflow contract + map) are updated together and called out.
- [ ] No new duplicate source of truth was introduced without consolidation.

## Claims & Data
- [ ] Performance or integration claims are backed by data or explicitly labeled estimates.
- [ ] Line-number references are avoided or validated; prefer function names/snippets.
- [ ] Schema fields and counts referenced in plans/pseudocode are verified against validator scripts (e.g., `plans/prd_audit_check.sh`).
- [ ] Cache key/dependency scope claims are traced to actual inputs (prompt templates, slice prep, validators, runner scripts).
- [ ] Fail-closed audit: any `|| true`, suppressed errors, or ignored exits are reviewed for silent-success risk.
- [ ] New workflow paths include at least one integration/smoke test (or an explicit rationale for omission).

## Operational & Org Lens
- [ ] Operational impact: day-to-day workflows, incident response, and debugging paths are reviewed for regressions or new toil.
- [ ] Tooling integration: interactions with editors/IDEs, git hooks, and pre-commit are assessed (including expected failures).
- [ ] Org/process fit: ownership, handoffs, and bus-factor risks are identified with a mitigation note.
- [ ] Data/privacy: telemetry or artifacts containing developer/workstation identity are reviewed for handling, retention, and exposure.
- [ ] Failure recovery: explicit “when things go wrong” paths are documented beyond the happy path.
- [ ] Mental model risks: likely developer misunderstandings are called out with clarifying guidance.
- [ ] Performance beyond hashing: I/O patterns, parallel execution, and contention are assessed.
- [ ] Documentation discoverability: where developers learn this behavior is identified (docs, README, workflow guide).
- [ ] Ralph interaction: effects on Ralph runs, even when designed for manual runs, are checked for edge cases.
- [ ] Maintenance burden: long-term costs of manifests/lints/guards are assessed with an owner or follow-up.

## Block Conditions
Mark the PR BLOCKED if any are true:
- Evidence section is empty, vague, or missing artifacts.
- Compounding sections (AGENTS.md updates / Elevation plan) are empty or non-enforceable.
- Requirements touched cannot be cited.
