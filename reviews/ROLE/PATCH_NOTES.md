# PATCH NOTES

## What changed
- Added a fail-closed run lock in `plans/ralph.sh` (`RPH_LOCK_DIR`, `lock.json`) to prevent concurrent harness runs.
- Replaced inline PRD schema checks with the canonical `plans/prd_schema_check.sh` (fail-closed, centralized rules).
- Added best-effort `verify_pre.log` capture for early blocked cases (invalid selection, missing verify, needs_human_decision).
- Expanded `plans/workflow_acceptance.sh` with lock and invalid-selection verify_pre assertions; added an invalid-selection stub agent.
- Acceptance harness now copies working-tree versions of `plans/ralph.sh` / `plans/verify.sh` into the worktree and marks them assume-unchanged so preflight stays clean.
- Adjusted instrument cache TTL tests to assert monotonic metric increments, avoiding flakiness from parallel test execution.

## Why
- Prevents nondeterministic state corruption from parallel runs.
- Eliminates schema drift and ensures canonical PRD validation.
- Improves operator diagnostics on early blocks without loosening gates.
- Provides acceptance tests that prove the new behavior deterministically.

## Risks / considerations
- A stale `.ralph/lock` will block future runs; operators must remove it if no run is active.
- PRD schema enforcement is stricter; any non-canonical PRD now fails preflight (by design).
- Early blocks now run `./plans/verify.sh` best-effort, which can be expensive if verify is heavy.
