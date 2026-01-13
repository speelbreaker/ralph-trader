- Added workflow skills read policy (WF-4.7): All agents MUST read `docs/skills/workflow.md` before starting any task.
- Created `docs/skills/workflow.md` to capture recurring corrections and preferred patterns for the workflow harness (manual-only, no automation).
- Added acceptance stubs for delete-test-and-commit and commit-progress-without-mark_pass.
- Strengthened acceptance tests for cheating detection (exit 9 + reason), needs_human_decision blocking, self-heal reverting to last_good_ref, and max-iters blocked_max_iters reason (with circuit breaker disabled).
- Init hygiene: create plans/ideas.md and plans/pause.md when missing.

Tests:
- ./plans/workflow_acceptance.sh
- CI=1 ./plans/verify.sh

Rationale / Process Notes:
- The workflow skills document provides a manual-only memory system for agents to learn from repeated patterns without adding new automation or gates.
- Acceptance tests were adjusted to reach the intended gates without changing Ralph behavior: scope.touch includes files the stub agents modify, contract review is forced PASS where needed, and the circuit breaker is disabled for max-iters so it reaches the blocked_max_iters path.
- Cheating detection now asserts exit code 9, blocked reason, and that HEAD matches last_good_ref after self-heal, aligning with the harness's rollback behavior.
