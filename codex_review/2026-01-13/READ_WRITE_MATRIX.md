# READ_WRITE_MATRIX.md

Action codes: R = read, W = write/modify, C = create

| Step | Command | Artifact | Action |
| --- | --- | --- | --- |
| INIT-1 preflight | ./plans/init.sh | plans/prd.json | R |
| INIT-1 preflight | ./plans/init.sh | CONTRACT.md (or specs/CONTRACT.md) | R |
| INIT-1 preflight | ./plans/init.sh | IMPLEMENTATION_PLAN.md (or specs/IMPLEMENTATION_PLAN.md) | R |
| INIT-1 preflight | ./plans/init.sh | plans/prd_schema_check.sh | R (exec) |
| INIT-1 preflight | ./plans/init.sh | plans/verify.sh | R/W (chmod +x) |
| INIT-1 preflight | ./plans/init.sh | plans/contract_review_validate.sh | R/W (chmod +x if present) |
| INIT-1 preflight | ./plans/init.sh | plans/progress.txt | C (if missing) |
| INIT-1 preflight | ./plans/init.sh | plans/ideas.md | C (if missing) |
| INIT-1 preflight | ./plans/init.sh | plans/pause.md | C (if missing) |
| INIT-1 preflight | ./plans/init.sh | .ralph/ | C |
| INIT-1 preflight | ./plans/init.sh | plans/logs/ | C |
| INIT-1 optional verify | ./plans/init.sh (INIT_RUN_VERIFY=1) | plans/verify.sh | R (exec) |

| PRD-SCHEMA | ./plans/prd_schema_check.sh "$PRD_FILE" | plans/prd.json | R |

| RALPH-0 lock+state | ./plans/ralph.sh | .ralph/lock/lock.json | C |
| RALPH-0 lock+state | ./plans/ralph.sh | .ralph/state.json | C/W |
| RALPH-0 lock+state | ./plans/ralph.sh | plans/logs/ralph.<ts>.log | C/W |
| RALPH-0 preflight | ./plans/ralph.sh | plans/prd.json | R |
| RALPH-0 preflight | ./plans/ralph.sh | plans/prd_schema_check.sh | R (exec) |
| RALPH-0 preflight | ./plans/ralph.sh | plans/verify.sh | R (exec) |
| RALPH-0 preflight | ./plans/ralph.sh | plans/update_task.sh | R (exec check) |
| RALPH-0 preflight | ./plans/ralph.sh | CONTRACT.md / IMPLEMENTATION_PLAN.md | R |
| RALPH-0 preflight | ./plans/ralph.sh | plans/progress.txt | R (existence) |
| RALPH-0 blocked | ./plans/ralph.sh | .ralph/blocked_*/blocked_item.json | C (on failure) |
| RALPH-0 blocked | ./plans/ralph.sh | .ralph/blocked_*/prd_snapshot.json | C (on failure) |

| RALPH-1 snapshot | ./plans/ralph.sh | .ralph/iter_*/prd_before.json | C |
| RALPH-1 snapshot | ./plans/ralph.sh | .ralph/iter_*/progress_tail_before.txt | C |
| RALPH-1 snapshot | ./plans/ralph.sh | .ralph/iter_*/head_before.txt | C |

| RALPH-2 selection | ./plans/ralph.sh | plans/prd.json | R |
| RALPH-2 selection | ./plans/ralph.sh | .ralph/iter_*/selected.json | C |
| RALPH-2 selection (agent mode) | $RPH_AGENT_CMD | .ralph/iter_*/selection.out | C |

| RALPH-3 verify_pre | ./plans/verify.sh "$RPH_VERIFY_MODE" | .ralph/iter_*/verify_pre.log | C |

| RALPH-4 prompt+agent | ./plans/ralph.sh | .ralph/iter_*/prompt.txt | C |
| RALPH-4 prompt+agent | $RPH_AGENT_CMD | .ralph/iter_*/agent.out | C |

| RALPH-5 gate: scope/cheat | ./plans/ralph.sh | plans/prd.json (scope.touch/avoid) | R |
| RALPH-5 gate: scope/cheat | ./plans/ralph.sh | .ralph/iter_*/diff_for_cheat_check.patch | C |
| RALPH-5 gate: scope/cheat | ./plans/ralph.sh | .ralph/iter_*/diff_for_cheat_check.filtered.patch | C |
| RALPH-5 gate: dirty | ./plans/ralph.sh | .ralph/blocked_*/dirty_status.txt | C (on dirty) |

| RALPH-6 verify_post | ./plans/verify.sh "$RPH_VERIFY_MODE" | .ralph/iter_*/verify_post.log | C |
| RALPH-6 story verify | bash -c "<cmd>" (from verify[]) | .ralph/iter_*/story_verify.log | C |
| RALPH-6 story verify | ./plans/ralph.sh | plans/story_verify_allowlist.txt | R |

| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | CONTRACT.md | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | plans/prd.json | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/state.json | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/selected.json | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/head_before.txt | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/head_after.txt | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/prd_before.json | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/prd_after.json | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/diff.patch | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/verify_post.log | R |
| RALPH-7 contract_check | ./plans/contract_check.sh <iter>/contract_review.json | .ralph/iter_*/contract_review.json | C |

| RALPH-8 contract_review_validate | ./plans/contract_review_validate.sh <iter>/contract_review.json | .ralph/iter_*/contract_review.json | R |
| RALPH-8 contract_review_validate | ./plans/contract_review_validate.sh <iter>/contract_review.json | docs/schemas/contract_review.schema.json | R |

| RALPH-9 pass flip | ./plans/update_task.sh <ID> true | plans/prd.json | W |
| RALPH-9 pass flip | ./plans/update_task.sh <ID> true | .ralph/state.json | R |

| RALPH-10 progress_gate | ./plans/ralph.sh | plans/progress.txt | R |
| RALPH-10 progress_gate | ./plans/ralph.sh | .ralph/iter_*/progress_appended.txt | C |

| RALPH-11 save_iter_after | ./plans/ralph.sh | .ralph/iter_*/prd_after.json | C |
| RALPH-11 save_iter_after | ./plans/ralph.sh | .ralph/iter_*/progress_tail_after.txt | C |
| RALPH-11 save_iter_after | ./plans/ralph.sh | .ralph/iter_*/head_after.txt | C |
| RALPH-11 save_iter_after | ./plans/ralph.sh | .ralph/iter_*/diff.patch | C |

| RALPH-12 final verify | ./plans/verify.sh "$RPH_VERIFY_MODE" | .ralph/final_verify_*.log | C |

| TRACE-1 traceability gate | ./plans/workflow_contract_gate.sh | specs/WORKFLOW_CONTRACT.md | R |
| TRACE-1 traceability gate | ./plans/workflow_contract_gate.sh | plans/workflow_contract_map.json | R |

| ROTATE-PROGRESS | ./plans/rotate_progress.py --file plans/progress.txt --archive plans/progress_archive.txt | plans/progress.txt | R |
| ROTATE-PROGRESS | ./plans/rotate_progress.py --file plans/progress.txt --archive plans/progress_archive.txt | plans/progress_archive.txt | C/W |

| VERIFY-1 rust/python/node gates | ./plans/verify.sh <mode> | Cargo.toml / Cargo.lock / pyproject.toml / package.json | R |
| VERIFY-2 optional F1 cert | ./plans/verify.sh <mode> (RUN_F1_CERT=1) | artifacts/F1_CERT.json | C/W |
| VERIFY-3 optional E2E | ./plans/verify.sh <mode> (E2E=1) | artifacts/e2e/* | C/W |

| ACCEPT-1 worktree setup | ./plans/workflow_acceptance.sh | .ralph/workflow_acceptance_* | C |
| ACCEPT-2 stubs | ./plans/workflow_acceptance.sh | .ralph/workflow_acceptance_*/.ralph/stubs/* | C |
| ACCEPT-3 acceptance runs | ./plans/workflow_acceptance.sh -> ./plans/ralph.sh | .ralph/workflow_acceptance_*/.ralph/blocked_* | C |
| ACCEPT-4 acceptance logs | ./plans/workflow_acceptance.sh | .ralph/workflow_acceptance_*/.ralph/test*.log | C |
