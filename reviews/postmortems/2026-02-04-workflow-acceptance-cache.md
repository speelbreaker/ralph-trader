# PR Postmortem (Agent-Filled)

## 0) What shipped
- Feature/behavior: Added shared clone cache wiring for workflow acceptance parallel runs (WORKFLOW_ACCEPTANCE_CACHE_DIR) with acceptance assertions and overlay support for workflow_acceptance_parallel.sh. Preflight now honors CONTRACT_FILE and POSTMORTEM_GATE overrides; pre-commit hook now enforces repo-root execution.
- What value it has (what problem it solves, upgrade provides): Cuts workflow acceptance setup time by reusing the git object store across workers while keeping full coverage; keeps preflight/postmortem behavior consistent with verify/ralph and avoids hook misfires from non-root working directories.
- Governing contract: specs/WORKFLOW_CONTRACT.md

## 1) Constraint (ONE)
- How it manifested (2-3 concrete symptoms): Full workflow acceptance took ~1 hour even for tiny workflow changes; parallel runner paid full clone cost per worker; local iteration required long waits before push.
- Time/token drain it caused: Multiple long-running acceptance passes during small workflow edits.
- Workaround I used this PR (exploit): Shared git cache for clone-based workers and a default cache path in the parallel runner.
- Next-agent default behavior (subordinate): Keep WORKFLOW_ACCEPTANCE_CACHE_DIR enabled (default) for workflow acceptance parallel runs.
- Permanent fix proposal (elevate): Add cache hit/miss and setup-time metrics to workflow acceptance logs to enforce performance budgets.
- Smallest increment: Log cache mode/dir and clone time in workflow_acceptance.sh.
- Validation (proof it got better): Compare workflow acceptance setup time before/after with the same WORKFLOW_ACCEPTANCE_JOBS on the same machine.

## 2) Given what I built, what's the single best follow-up PR, and what 1-3 upgrades are worth considering next? Include smallest increment + how we validate.
- Response: Add lightweight timing around worktree setup and cache prep (per-worker and total) with a warning if setup exceeds a threshold; validate by verifying setup time reduction in the workflow acceptance timing summary.

## 3) Given what I built and the pain I hit (top sinks + failure modes), what 1-3 enforceable AGENTS.md rules should we add so the next agent doesn't repeat it?
- Response: Require workflow changes that affect acceptance runtime to add or update a performance note in WORKFLOW_FRICTION.md and to include a cache/parallelism check in acceptance coverage.
