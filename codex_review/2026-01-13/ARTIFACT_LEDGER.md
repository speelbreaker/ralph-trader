# ARTIFACT_LEDGER.md

Legend
- Required? = Yes/No/Conditional (with condition)
- Lifecycle = how/when it is created/updated

Inputs and canonical references
| Artifact path | Format | Producer (command/actor) | Consumer(s) | Required? | Lifecycle |
| --- | --- | --- | --- | --- | --- |
| specs/WORKFLOW_CONTRACT.md | Markdown | Human maintainer | Human/agent (manual), workflow rules referenced by plans/ralph.sh behavior | Yes (contract) | Manual edits; source of truth for workflow rules |
| CONTRACT.md (fallback: specs/CONTRACT.md) | Markdown | Human maintainer | plans/init.sh (existence check), plans/contract_check.sh (content search) | Yes (init + contract check) | Manual edits; required input |
| IMPLEMENTATION_PLAN.md (fallback: specs/IMPLEMENTATION_PLAN.md) | Markdown | Human maintainer | plans/init.sh (existence check), plans/ralph.sh preflight | Yes | Manual edits; required input |
| plans/prd.json | JSON | Story Cutter / human (specs/WORKFLOW_CONTRACT.md §4.1) | plans/init.sh, plans/ralph.sh, plans/contract_check.sh, plans/update_task.sh, plans/workflow_acceptance.sh (uses alternate PRD path) | Yes | Append-only edits via plans/update_task.sh (passes flips); otherwise manual generation |
| plans/progress.txt | Text (append-only) | plans/init.sh (creates skeleton), implementer/agent appends | plans/ralph.sh progress_gate | Yes | Append-only; ralph enforces required fields |
| plans/story_verify_allowlist.txt | Text (one command per line) | Human maintainer | plans/ralph.sh run_story_verify | Conditional: required if any verify[] commands beyond ./plans/verify.sh | Manual edits |
| plans/prd_schema_check.sh | Shell script | Human maintainer | plans/init.sh, plans/ralph.sh preflight | Yes | Script file; executed each run |
| plans/verify.sh | Shell script | Human maintainer | plans/init.sh (exec bit), plans/ralph.sh (verify_pre/verify_post/final), humans/CI | Yes | Script file; prints VERIFY_SH_SHA on each run |
| plans/contract_check.sh | Shell script | Human maintainer | plans/ralph.sh ensure_contract_review | Yes (iteration gate) | Script file; writes contract_review.json |
| plans/contract_review_validate.sh | Shell script | Human maintainer | plans/contract_check.sh, plans/ralph.sh (contract_review_ok) | Yes | Script file; validates contract_review.json schema |
| docs/schemas/contract_review.schema.json | JSON schema | Human maintainer | plans/contract_review_validate.sh | Yes by spec (specs/WORKFLOW_CONTRACT.md §7) | Manual edits; schema source of truth for contract_review.json |
| plans/update_task.sh | Shell script | Human maintainer | plans/ralph.sh (pass flip) | Yes | Script file; updates plans/prd.json |
| plans/init.sh | Shell script | Human maintainer | Human operator / CI | Yes by process | Script file |
| plans/ralph.sh | Shell script | Human maintainer | Human operator / CI | Yes by process | Script file |
| plans/workflow_contract_gate.sh | Shell script | Human maintainer | Human operator / CI (traceability gate), plans/workflow_acceptance.sh (Test 11) | Yes by workflow contract §12 | Script file; validates mapping coverage |
| plans/workflow_contract_map.json | JSON | Human maintainer | plans/workflow_contract_gate.sh | Yes by workflow contract §12 | Manual edits; mapping of WF rule IDs to enforcement/tests |
| plans/workflow_acceptance.sh | Shell script | Human maintainer | Human operator / CI | Yes by workflow contract §12 | Script file |
| plans/ideas.md | Text (append-only) | plans/init.sh (if missing), humans/agents | Humans | Optional | Append-only deferred ideas log |
| plans/pause.md | Text | plans/init.sh (if missing), humans/agents | Humans | Optional | Short pause/handoff note |

Runtime state and logs
| Artifact path | Format | Producer (command/actor) | Consumer(s) | Required? | Lifecycle |
| --- | --- | --- | --- | --- | --- |
| .ralph/ | Directory | plans/init.sh, plans/ralph.sh | plans/ralph.sh, plans/workflow_acceptance.sh, humans | Yes (runtime) | Created if missing; holds all runtime artifacts |
| plans/logs/ | Directory | plans/init.sh, plans/ralph.sh | humans | Yes (runtime) | Created if missing |
| plans/logs/ralph.<timestamp>.log | Text log | plans/ralph.sh | humans | Yes (per run) | New file each run |
| .ralph/lock/lock.json | JSON | plans/ralph.sh acquire_lock | plans/ralph.sh (lock check), humans | Yes (concurrency gate) | Created per run; removed on exit |
| .ralph/state.json | JSON | plans/ralph.sh state_merge | plans/ralph.sh, plans/update_task.sh, plans/contract_check.sh | Yes | Created if missing; updated each iteration |
| .ralph/last_good_ref | Text (git ref) | plans/ralph.sh | plans/ralph.sh (self-heal) | Conditional (RPH_SELF_HEAL=1) | Created on first run; updated when iteration passes |
| .ralph/last_failure_path | Text (path) | plans/ralph.sh | plans/ralph.sh (prompt note), humans | Conditional (verify_post failure) | Overwritten with last failed iter dir |
| .ralph/rate_limit.json | JSON | plans/ralph.sh | plans/ralph.sh rate_limit_before_call | Conditional (RPH_RATE_LIMIT_ENABLED=1) | Updated per agent call |
| plans/progress_archive.txt | Text | plans/rotate_progress.py (invoked by plans/ralph.sh rotate_progress) | humans | Conditional (rotate_progress.py executable) | Append/rotate archive |

Iteration artifacts (.ralph/iter_*/)
| Artifact path | Format | Producer (command/actor) | Consumer(s) | Required? | Lifecycle |
| --- | --- | --- | --- | --- | --- |
| .ralph/iter_*/selected.json | JSON | plans/ralph.sh | plans/contract_check.sh, humans | Yes (specs/WORKFLOW_CONTRACT.md §6) | New per iteration |
| .ralph/iter_*/selection.out | Text | plans/ralph.sh (agent selection mode) | plans/ralph.sh (parses), humans | Conditional (RPH_SELECTION_MODE=agent) | New per iteration |
| .ralph/iter_*/prd_before.json | JSON | plans/ralph.sh save_iter_artifacts | plans/contract_check.sh, humans | Yes | New per iteration |
| .ralph/iter_*/prd_after.json | JSON | plans/ralph.sh save_iter_after | plans/contract_check.sh, humans | Yes | New per iteration |
| .ralph/iter_*/progress_tail_before.txt | Text | plans/ralph.sh save_iter_artifacts | humans | Yes | New per iteration |
| .ralph/iter_*/progress_tail_after.txt | Text | plans/ralph.sh save_iter_after | humans | Yes | New per iteration |
| .ralph/iter_*/head_before.txt | Text | plans/ralph.sh save_iter_artifacts | plans/contract_check.sh, humans | Yes | New per iteration |
| .ralph/iter_*/head_after.txt | Text | plans/ralph.sh save_iter_after | plans/contract_check.sh, humans | Yes | New per iteration |
| .ralph/iter_*/diff.patch | Unified diff | plans/ralph.sh save_iter_after | plans/contract_check.sh, humans | Yes | New per iteration |
| .ralph/iter_*/diff_for_cheat_check.patch | Unified diff | plans/ralph.sh detect_cheating | plans/ralph.sh detect_cheating, humans | Conditional (RPH_CHEAT_DETECTION!=off) | New per iteration |
| .ralph/iter_*/diff_for_cheat_check.filtered.patch | Unified diff | plans/ralph.sh detect_cheating | plans/ralph.sh detect_cheating, humans | Conditional (RPH_CHEAT_DETECTION!=off) | New per iteration |
| .ralph/iter_*/prompt.txt | Text | plans/ralph.sh | humans | Yes | New per iteration |
| .ralph/iter_*/agent.out | Text | agent process via plans/ralph.sh | plans/ralph.sh (mark_pass/COMPLETE scan), humans | Yes | New per iteration |
| .ralph/iter_*/verify_pre.log | Text log | plans/ralph.sh run_verify -> plans/verify.sh | plans/ralph.sh (VERIFY_SH_SHA check), humans | Yes | New per iteration |
| .ralph/iter_*/verify_pre_after_heal.log | Text log | plans/ralph.sh (self-heal path) | plans/ralph.sh, humans | Conditional (RPH_SELF_HEAL=1) | New per iteration when used |
| .ralph/iter_*/verify_post.log | Text log | plans/ralph.sh run_verify -> plans/verify.sh | plans/ralph.sh, plans/contract_check.sh, humans | Yes | New per iteration |
| .ralph/iter_*/story_verify.log | Text log | plans/ralph.sh run_story_verify | humans | Conditional (story verify commands present) | New per iteration |
| .ralph/iter_*/contract_review.json | JSON | plans/contract_check.sh (or write_contract_review_fail) | plans/ralph.sh (contract_review_ok), plans/contract_review_validate.sh, humans | Yes when verify_post green (specs/WORKFLOW_CONTRACT.md §7) | New per iteration |
| .ralph/iter_*/progress_appended.txt | Text | plans/ralph.sh progress_gate | plans/ralph.sh progress_gate, humans | Conditional (progress_gate executed) | New per iteration |

Blocked artifacts (.ralph/blocked_*/)
| Artifact path | Format | Producer (command/actor) | Consumer(s) | Required? | Lifecycle |
| --- | --- | --- | --- | --- | --- |
| .ralph/blocked_*/prd_snapshot.json | JSON | plans/ralph.sh write_blocked_* | humans | Yes when blocked | New per block |
| .ralph/blocked_*/blocked_item.json | JSON | plans/ralph.sh write_blocked_* | humans | Yes when blocked | New per block |
| .ralph/blocked_*/verify_pre.log | Text log | plans/ralph.sh attempt_blocked_verify_pre | humans | Best-effort (spec §6) | New per block when verify_pre runs |
| .ralph/blocked_*/verify_post.log | Text log | plans/ralph.sh write_blocked_with_state | humans | Conditional (when verify_post exists) | New per block when available |
| .ralph/blocked_*/state.json | JSON | plans/ralph.sh write_blocked_with_state | humans | Conditional (when state exists) | New per block when available |
| .ralph/blocked_*/dirty_status.txt | Text | plans/ralph.sh dirty_worktree gate | humans | Conditional (dirty worktree block) | New per block when used |
| .ralph/blocked_incomplete_*/* | Mixed | plans/ralph.sh write_blocked_basic | humans | Conditional (completion blocked) | New per block |
| .ralph/blocked_final_verify_*/* | Mixed | plans/ralph.sh run_final_verify | humans | Conditional (final verify fail) | New per block |

Verification evidence artifacts
| Artifact path | Format | Producer (command/actor) | Consumer(s) | Required? | Lifecycle |
| --- | --- | --- | --- | --- | --- |
| artifacts/F1_CERT.json | JSON | python/tools/f1_certify.py (invoked by plans/verify.sh with RUN_F1_CERT=1) | plans/verify.sh (promotion gate) | Conditional (VERIFY_MODE=promotion or REQUIRE_F1_CERT=1) | Generated on demand |
| artifacts/e2e/ | Directory | plans/verify.sh (E2E=1) | humans/CI | Conditional (E2E=1) | Created per E2E run |
| artifacts/e2e/playwright-report | Directory | plans/verify.sh capture_e2e_artifacts | humans/CI | Conditional (E2E=1 and playwright-report exists) | Overwritten per run |
| artifacts/e2e/playwright-test-results | Directory | plans/verify.sh capture_e2e_artifacts | humans/CI | Conditional (E2E=1 and test-results exists) | Overwritten per run |
| artifacts/e2e/cypress-screenshots | Directory | plans/verify.sh capture_e2e_artifacts | humans/CI | Conditional (E2E=1 and cypress/screenshots exists) | Overwritten per run |
| artifacts/e2e/cypress-videos | Directory | plans/verify.sh capture_e2e_artifacts | humans/CI | Conditional (E2E=1 and cypress/videos exists) | Overwritten per run |

Workflow acceptance harness artifacts (created inside worktree)
| Artifact path | Format | Producer (command/actor) | Consumer(s) | Required? | Lifecycle |
| --- | --- | --- | --- | --- | --- |
| .ralph/workflow_acceptance_* | Directory (git worktree) | plans/workflow_acceptance.sh (git worktree add) | plans/workflow_acceptance.sh | Yes (during acceptance) | Created per run; removed on exit |
| .ralph/workflow_acceptance_*/.ralph/stubs/* | Shell scripts | plans/workflow_acceptance.sh | plans/ralph.sh (stubbed VERIFY_SH / agent) | Yes (acceptance tests) | Created per run; removed with worktree |
| .ralph/workflow_acceptance_*/.ralph/test*.log | Text logs | plans/workflow_acceptance.sh | humans | Conditional (per test) | Created per run; removed with worktree |
| .ralph/workflow_acceptance_*/.ralph/blocked_* | Mixed | plans/ralph.sh (inside worktree) | plans/workflow_acceptance.sh assertions | Conditional (expected in tests) | Created per test; removed with worktree |
