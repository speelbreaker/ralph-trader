# TRACEABILITY_MATRIX.md
| Rule ID | Title | Enforcement (script/location) | Artifacts | Tests |
| --- | --- | --- | --- | --- |
| WF-0.1 | Trading behavior precedence | Human: contract review + agent instructions | CONTRACT.md<br>plans/progress.txt | manual |
| WF-0.2 | Workflow contract is canonical | Human: change control | specs/WORKFLOW_CONTRACT.md | manual |
| WF-1.1 | CONTRACT.md required | plans/init.sh<br>plans/ralph.sh preflight | CONTRACT.md | manual |
| WF-1.2 | IMPLEMENTATION_PLAN.md required | plans/init.sh<br>plans/ralph.sh preflight | IMPLEMENTATION_PLAN.md | manual |
| WF-1.3 | plans/prd.json required | plans/init.sh<br>plans/ralph.sh preflight | plans/prd.json | plans/workflow_acceptance.sh (Test 12) |
| WF-1.4 | plans/ralph.sh required | Human: harness invocation | plans/ralph.sh | manual |
| WF-1.5 | plans/verify.sh required | plans/init.sh<br>plans/ralph.sh preflight | plans/verify.sh | manual |
| WF-1.6 | plans/progress.txt required | plans/init.sh<br>plans/ralph.sh progress_gate | plans/progress.txt | plans/workflow_acceptance.sh (Test 9) |
| WF-2.1 | Contract alignment mandatory | plans/contract_check.sh<br>plans/ralph.sh needs_human_decision gate | .ralph/iter_*/contract_review.json<br>.ralph/blocked_* | plans/workflow_acceptance.sh (Tests 6-8) |
| WF-2.2 | Verification mandatory | plans/ralph.sh verify_pre/verify_post<br>plans/prd_schema_check.sh<br>plans/update_task.sh | .ralph/iter_*/verify_pre.log<br>.ralph/iter_*/verify_post.log<br>.ralph/state.json | plans/workflow_acceptance.sh (Test 2) |
| WF-2.3 | WIP=1 (one story + one commit) | plans/ralph.sh selection<br>plans/contract_check.sh commit count | .ralph/iter_*/selected.json<br>.ralph/iter_*/contract_review.json | manual |
| WF-2.4 | Slices executed in order | plans/ralph.sh ACTIVE_SLICE selection | .ralph/iter_*/selected.json | plans/workflow_acceptance.sh (Test 16) |
| WF-2.5 | No cheating | plans/ralph.sh detect_cheating | .ralph/iter_*/diff_for_cheat_check.patch | plans/workflow_acceptance.sh (Test 15) |
| WF-2.6 | Fail closed with diagnostic artifacts | plans/ralph.sh write_blocked_* | .ralph/blocked_*/blocked_item.json | plans/workflow_acceptance.sh (Tests 1-8) |
| WF-3.1 | PRD JSON shape | plans/prd_schema_check.sh | plans/prd.json | plans/workflow_acceptance.sh (Test 1) |
| WF-3.2 | PRD top-level keys required | plans/prd_schema_check.sh | plans/prd.json | plans/workflow_acceptance.sh (Test 1) |
| WF-3.3 | Per-item required fields + acceptance/steps/verify | plans/prd_schema_check.sh | plans/prd.json | plans/workflow_acceptance.sh (Test 1) |
| WF-3.4 | needs_human_decision requires human_blocker | plans/prd_schema_check.sh | plans/prd.json | plans/workflow_acceptance.sh (Test 1) |
| WF-3.5 | PRD item required fields list | plans/prd_schema_check.sh | plans/prd.json | plans/workflow_acceptance.sh (Test 1) |
| WF-3.6 | human_blocker schema | plans/prd_schema_check.sh | plans/prd.json | plans/workflow_acceptance.sh (Test 1) |
| WF-4.1 | Story Cutter responsibilities | Human: Story Cutter process | plans/prd.json | manual |
| WF-4.2 | Auditor outputs | Human: Auditor process | plans/prd_audit.json | manual |
| WF-4.3 | PRD patcher constraints | Human: PRD patcher process<br>plans/ralph.sh blocks agent PRD edits | plans/prd.json | manual |
| WF-4.4 | Implementer duties | plans/ralph.sh prompt + progress_gate + commit check | plans/progress.txt<br>.ralph/iter_*/agent.out | plans/workflow_acceptance.sh (Test 9) |
| WF-4.5 | Contract Arbiter | plans/contract_check.sh | .ralph/iter_*/contract_review.json | plans/workflow_acceptance.sh (Tests 6-8) |
| WF-4.6 | Handoff hygiene | Human: implementer/maintainer | plans/progress.txt<br>docs/codebase/*<br>plans/ideas.md<br>plans/pause.md | manual |
| WF-5.0 | Ralph is the only allowed automation | Human: workflow policy | plans/ralph.sh | manual |
| WF-5.1 | Preflight invariants | plans/ralph.sh preflight | .ralph/blocked_* | plans/workflow_acceptance.sh (Tests 1,5,12) |
| WF-5.2 | Active slice gating | plans/ralph.sh select_next_item | .ralph/iter_*/selected.json | plans/workflow_acceptance.sh (Test 16) |
| WF-5.3 | Selection modes + validation | plans/ralph.sh selection logic | .ralph/iter_*/selected.json<br>.ralph/iter_*/selection.out | plans/workflow_acceptance.sh (Test 4) |
| WF-5.4 | Hard stop on needs_human_decision | plans/ralph.sh needs_human_decision gate | .ralph/blocked_* | plans/workflow_acceptance.sh (Test 14) |
| WF-5.5 | verify_pre / verify_post gates | plans/ralph.sh run_verify | .ralph/iter_*/verify_pre.log<br>.ralph/iter_*/verify_post.log | plans/workflow_acceptance.sh (Test 2) |
| WF-5.5.1 | Endpoint-level test gate | plans/verify.sh endpoint gate | plans/verify.sh output | manual |
| WF-5.6 | Story verify requirement gate | plans/ralph.sh verify[] contains ./plans/verify.sh | .ralph/blocked_* | plans/workflow_acceptance.sh (Test 1) |
| WF-5.7 | Story verify allowlist gate | plans/ralph.sh run_story_verify | plans/story_verify_allowlist.txt<br>.ralph/iter_*/story_verify.log | manual |
| WF-5.8 | Optional self-heal | plans/ralph.sh self-heal | .ralph/last_good_ref<br>.ralph/iter_*/verify_pre_after_heal.log | plans/workflow_acceptance.sh (Test 18) |
| WF-5.9 | Completion conditions | plans/ralph.sh completion_requirements_met | .ralph/blocked_incomplete_*<br>.ralph/final_verify_*.log | plans/workflow_acceptance.sh (Test 3) |
| WF-5.10 | Scope enforcement gate | plans/ralph.sh scope_gate | .ralph/blocked_* | manual |
| WF-5.11 | Rate limiting + circuit breaker | plans/ralph.sh rate_limit_before_call<br>plans/ralph.sh circuit breaker | .ralph/rate_limit.json<br>.ralph/state.json<br>.ralph/blocked_* | manual |
| WF-6.1 | Iteration artifacts required | plans/ralph.sh save_iter_* + verify_iteration_artifacts | .ralph/iter_*/* | plans/workflow_acceptance.sh (Test 9) |
| WF-6.2 | Blocked artifacts required | plans/ralph.sh write_blocked_* | .ralph/blocked_*/blocked_item.json<br>.ralph/blocked_*/verify_pre.log | plans/workflow_acceptance.sh (Tests 1-5) |
| WF-6.3 | Optional diagnostics | plans/ralph.sh (optional writes) | .ralph/iter_*/story_verify.log<br>.ralph/iter_*/diff_for_cheat_check.patch | manual |
| WF-7.1 | Contract check after verify_post green | plans/ralph.sh ensure_contract_review | .ralph/iter_*/contract_review.json | plans/workflow_acceptance.sh (Tests 6-8) |
| WF-7.2 | contract_review.json must be produced | plans/contract_check.sh | .ralph/iter_*/contract_review.json | plans/workflow_acceptance.sh (Tests 6-8) |
| WF-7.3 | contract_review.json must conform to schema | plans/contract_review_validate.sh | docs/schemas/contract_review.schema.json | plans/workflow_acceptance.sh (Test 10) |
| WF-7.4 | Fail-closed triggers | Human: review policy | plans/contract_check.sh | manual |
| WF-8.1 | CI executes verify.sh | CI config | .github/workflows/* | manual |
| WF-8.2 | verify.sh prints VERIFY_SH_SHA | plans/verify.sh | plans/verify.sh output | plans/workflow_acceptance.sh (Test 4) |
| WF-8.3 | Ralph captures VERIFY_SH_SHA | plans/ralph.sh verify_log_has_sha | .ralph/iter_*/verify_pre.log<br>.ralph/iter_*/verify_post.log | plans/workflow_acceptance.sh (Test 4) |
| WF-8.4 | CI logs contain VERIFY_SH_SHA | CI config | CI logs/artifacts | manual |
| WF-8.5 | verify.sh CI gate source check | plans/verify.sh CI_GATES_SOURCE check | plans/verify.sh output | manual |
| WF-9.1 | Progress log required fields | plans/ralph.sh progress_gate | plans/progress.txt<br>.ralph/iter_*/progress_appended.txt | plans/workflow_acceptance.sh (Test 9) |
| WF-10.1 | Human unblock protocol | Human: read blocked artifacts | .ralph/blocked_*/blocked_item.json | manual |
| WF-11.1 | Change control | Human: update workflow contract first | specs/WORKFLOW_CONTRACT.md | manual |
| WF-12.1 | Acceptance: preflight/PRD validation | plans/workflow_acceptance.sh | .ralph/blocked_* | plans/workflow_acceptance.sh (Tests 1,12) |
| WF-12.2 | Acceptance: baseline integrity | plans/workflow_acceptance.sh | .ralph/iter_*/verify_pre.log | plans/workflow_acceptance.sh (Test 13) |
| WF-12.3 | Acceptance: pass flipping integrity | plans/workflow_acceptance.sh | .ralph/iter_*/verify_post.log<br>.ralph/iter_*/contract_review.json | plans/workflow_acceptance.sh (Tests 2,6-9) |
| WF-12.4 | Acceptance: slice gating/blocked behavior | plans/workflow_acceptance.sh | .ralph/blocked_*<br>.ralph/iter_*/selected.json | plans/workflow_acceptance.sh (Tests 14,15,16) |
| WF-12.5 | Acceptance: completion semantics | plans/workflow_acceptance.sh | .ralph/blocked_incomplete_* | plans/workflow_acceptance.sh (Test 3) |
| WF-12.6 | Acceptance: anti-spin | plans/workflow_acceptance.sh | .ralph/blocked_* | plans/workflow_acceptance.sh (Test 17) |
| WF-12.7 | Acceptance: verify SHA observability | plans/workflow_acceptance.sh | .ralph/iter_*/verify_pre.log<br>.ralph/iter_*/verify_post.log | plans/workflow_acceptance.sh (Test 4) |
| WF-12.8 | Traceability gate | plans/workflow_contract_gate.sh | plans/workflow_contract_map.json | plans/workflow_acceptance.sh (Test 11) |
