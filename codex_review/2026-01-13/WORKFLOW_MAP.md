# WORKFLOW_MAP.md

Sources (explicit file paths)
- specs/WORKFLOW_CONTRACT.md
- CONTRACT.md (or specs/CONTRACT.md when CONTRACT.md missing)
- IMPLEMENTATION_PLAN.md (or specs/IMPLEMENTATION_PLAN.md when IMPLEMENTATION_PLAN.md missing)
- plans/prd.json
- plans/progress.txt
- plans/init.sh
- plans/ralph.sh
- plans/verify.sh
- plans/contract_check.sh
- plans/contract_review_validate.sh
- docs/schemas/contract_review.schema.json
- plans/prd_schema_check.sh
- plans/update_task.sh
- plans/workflow_contract_gate.sh
- plans/workflow_contract_map.json
- plans/workflow_acceptance.sh
- .ralph/ (runtime)
- plans/logs/

Actors (human + agents + scripts)
- Human operator: runs ./plans/init.sh, ./plans/ralph.sh, ./plans/verify.sh, ./plans/workflow_acceptance.sh; reviews plans/logs/ and .ralph/* artifacts. (specs/WORKFLOW_CONTRACT.md §4.4, §10)
- Agent process: command in RPH_AGENT_CMD (default "claude") executed by plans/ralph.sh. (plans/ralph.sh)
- Scripts: plans/ralph.sh, plans/verify.sh, plans/init.sh, plans/contract_check.sh, plans/contract_review_validate.sh, plans/prd_schema_check.sh, plans/update_task.sh, plans/workflow_contract_gate.sh, plans/workflow_acceptance.sh.

State storage (persistent across iterations)
- plans/prd.json (story backlog + passes flags) (plans/ralph.sh, plans/update_task.sh)
- plans/progress.txt (append-only log) (plans/ralph.sh progress_gate)
- .ralph/state.json (iteration + verify rc + rate-limit state) (plans/ralph.sh state_merge; read by plans/update_task.sh, plans/contract_check.sh)
- .ralph/last_good_ref (git ref for self-heal) (plans/ralph.sh)
- .ralph/last_failure_path (last failed iter dir) (plans/ralph.sh)
- .ralph/rate_limit.json (agent call rate limit window) (plans/ralph.sh)
- .ralph/lock/lock.json (lock metadata) (plans/ralph.sh)
- plans/logs/ralph.<timestamp>.log (run log) (plans/ralph.sh)

Mermaid (execution order + branching)
```mermaid
flowchart TD
  A[Human: ./plans/init.sh] --> B[Human: ./plans/ralph.sh]
  B --> C{Preflight ok?}
  C -- no --> Cx[.ralph/blocked_* + blocked_item.json]
  C -- yes --> D[Select story (harness/agent)]
  D --> E{needs_human_decision?}
  E -- yes --> Ex[.ralph/blocked_* + blocked_item.json]
  E -- no --> F[verify_pre: ./plans/verify.sh]
  F --> G{verify_pre green?}
  G -- no --> Gx[blocked_verify_pre_failed + .ralph/blocked_*]
  G -- yes --> H[Agent run: $RPH_AGENT_CMD]
  H --> I[Post-agent gates: PRD unchanged, clean tree, scope_gate, cheat detection]
  I --> J[verify_post: ./plans/verify.sh]
  J --> K{verify_post green?}
  K -- no --> Kx[blocked_verify_post_failed + .ralph/blocked_*]
  K -- yes --> L[contract_check.sh -> contract_review.json -> contract_review_validate.sh]
  L --> M{decision==PASS?}
  M -- no --> Mx[blocked_contract_review_failed + .ralph/blocked_*]
  M -- yes --> N{<mark_pass> emitted?}
  N -- yes --> O[update_task.sh passes=true + git commit]
  N -- no --> O2[no pass flip]
  O --> P[progress_gate: plans/progress.txt]
  O2 --> P
  P --> Q{all passes + verify_post green?}
  Q -- yes --> R[final_verify: ./plans/verify.sh -> .ralph/final_verify_*.log]
  R --> S[Exit 0]
  Q -- no --> T[Next iteration]

  subgraph Acceptance
    W[Human: ./plans/workflow_acceptance.sh]
    W --> W0[./plans/workflow_contract_gate.sh]
    W0 --> W1[git worktree add .ralph/workflow_acceptance_*]
    W1 --> W2[Run ./plans/ralph.sh with stub VERIFY_SH + stub agent]
    W2 --> W3[Assert blocked artifacts in worktree .ralph/]
  end
```

Execution steps with exact commands, inputs, outputs

1) plans/init.sh (deterministic preflight)
- Command: ./plans/init.sh
- Inputs: plans/prd.json, CONTRACT.md or specs/CONTRACT.md, IMPLEMENTATION_PLAN.md or specs/IMPLEMENTATION_PLAN.md, plans/prd_schema_check.sh, plans/verify.sh, git, jq. (plans/init.sh)
- Internal command: ./plans/prd_schema_check.sh "$PRD_FILE" (plans/init.sh)
- Outputs:
  - plans/progress.txt (created if missing) (plans/init.sh)
  - plans/ideas.md (created if missing) (plans/init.sh)
  - plans/pause.md (created if missing) (plans/init.sh)
  - .ralph/ (dir), plans/logs/ (dir) (plans/init.sh)
  - plans/verify.sh marked executable (plans/init.sh)
  - plans/contract_check.sh and plans/contract_review_validate.sh marked executable if present (plans/init.sh)
  - Optional: ./plans/verify.sh "$VERIFY_MODE" when INIT_RUN_VERIFY=1 (plans/init.sh)

2) plans/ralph.sh preflight (fail-closed)
- Command: ./plans/ralph.sh [MAX_ITERS]
- Inputs: plans/prd.json, plans/prd_schema_check.sh, plans/verify.sh, plans/update_task.sh, CONTRACT.md or specs/CONTRACT.md, IMPLEMENTATION_PLAN.md or specs/IMPLEMENTATION_PLAN.md, git, jq. (plans/ralph.sh)
- Internal command: ./plans/prd_schema_check.sh "$PRD_FILE" (plans/ralph.sh)
- Outputs:
  - .ralph/lock/lock.json (lock metadata) (plans/ralph.sh)
  - .ralph/state.json (initialized to {}) (plans/ralph.sh)
  - plans/logs/ralph.<timestamp>.log (run log) (plans/ralph.sh)
  - .ralph/blocked_* with blocked_item.json on preflight failure (plans/ralph.sh)
  - .ralph/blocked_*/verify_pre.log (best-effort on preflight failure) (plans/ralph.sh)

3) plans/ralph.sh iteration snapshot
- Command: ./plans/ralph.sh (internal save_iter_artifacts)
- Inputs: plans/prd.json, plans/progress.txt, git HEAD (plans/ralph.sh)
- Outputs: .ralph/iter_*/prd_before.json, progress_tail_before.txt, head_before.txt (plans/ralph.sh)

4) Selection (harness or agent)
- Command: ./plans/ralph.sh (internal select_next_item) OR RPH_AGENT_CMD for agent selection
- Inputs: plans/prd.json (items, passes, slice, priority) (plans/ralph.sh)
- Outputs: .ralph/iter_*/selected.json (always), .ralph/iter_*/selection.out (agent mode only) (plans/ralph.sh)
- Branch: invalid selection -> .ralph/blocked_* with blocked_item.json + verify_pre.log best-effort (plans/ralph.sh)

5) verify_pre baseline
- Command: ./plans/verify.sh "$RPH_VERIFY_MODE" (invoked by plans/ralph.sh run_verify)
- Inputs: repo state + toolchain; .github/workflows or CI_GATES_SOURCE=verify (plans/verify.sh)
- Outputs: .ralph/iter_*/verify_pre.log (plans/ralph.sh)
- Branch: verify_pre non-zero -> blocked_verify_pre_failed (plans/ralph.sh)

6) Agent execution
- Command: $RPH_AGENT_CMD "$RPH_PROMPT_FLAG" "$PROMPT" (or without prompt flag) (plans/ralph.sh)
- Inputs: prompt text embedding @plans/prd.json @plans/progress.txt @AGENTS.md (plans/ralph.sh)
- Outputs: .ralph/iter_*/prompt.txt, .ralph/iter_*/agent.out (plans/ralph.sh)

7) Post-agent gates (scope/cheat/clean)
- Command: ./plans/ralph.sh (internal checks)
- Inputs: git diff between head_before/head_after, scope.touch/scope.avoid from plans/prd.json, plans/story_verify_allowlist.txt (for later), RPH_CHEAT_DETECTION settings (plans/ralph.sh)
- Outputs:
  - .ralph/iter_*/diff.patch (save_iter_after)
  - .ralph/iter_*/diff_for_cheat_check.patch + diff_for_cheat_check.filtered.patch (detect_cheating)
  - .ralph/blocked_* with blocked_item.json on scope violation / cheat detection / dirty worktree (plans/ralph.sh)

8) verify_post + story verify
- Command: ./plans/verify.sh "$RPH_VERIFY_MODE" (verify_post), then bash -c "<cmd>" for each verify[] entry except ./plans/verify.sh (plans/ralph.sh)
- Inputs: repo state; story verify allowlist at plans/story_verify_allowlist.txt (plans/ralph.sh)
- Outputs:
  - .ralph/iter_*/verify_post.log
  - .ralph/iter_*/story_verify.log
- Branch: verify_post failure -> blocked_verify_post_failed; optional self-heal when RPH_SELF_HEAL=1 (plans/ralph.sh)

9) Contract alignment gate
- Command: CONTRACT_REVIEW_OUT=<iter>/contract_review.json CONTRACT_FILE=<...> PRD_FILE=<...> ./plans/contract_check.sh <iter>/contract_review.json (plans/ralph.sh)
- Internal command: ./plans/contract_review_validate.sh <iter>/contract_review.json (plans/contract_check.sh)
- Inputs: CONTRACT.md, plans/prd.json, .ralph/state.json, .ralph/iter_*/selected.json, head_before.txt, head_after.txt, prd_before.json, prd_after.json, diff.patch, verify_post.log, docs/schemas/contract_review.schema.json (plans/contract_check.sh + plans/contract_review_validate.sh)
- Outputs: .ralph/iter_*/contract_review.json (plans/contract_check.sh)
- Branch: decision != PASS -> blocked_contract_review_failed (plans/ralph.sh)

10) Pass flip + commit (when <mark_pass> emitted)
- Command: RPH_UPDATE_TASK_OK=1 RPH_STATE_FILE=.ralph/state.json ./plans/update_task.sh <ID> true (plans/ralph.sh)
- Inputs: plans/prd.json, .ralph/state.json (last_verify_post_rc) (plans/update_task.sh)
- Outputs: plans/prd.json (passes=true for selected ID), git commit or amend (plans/ralph.sh)

11) Progress gate
- Command: ./plans/ralph.sh (internal progress_gate)
- Inputs: plans/progress.txt (append-only log; must include timestamp, story id, summary, commands, evidence, next/gotcha) (plans/ralph.sh + specs/WORKFLOW_CONTRACT.md §9)
- Outputs: .ralph/iter_*/progress_appended.txt (tail of new append) (plans/ralph.sh)
- Branch: progress gate failure -> .ralph/blocked_* (plans/ralph.sh)

12) Completion + final verify
- Command: ./plans/verify.sh "$RPH_VERIFY_MODE" (run_final_verify) (plans/ralph.sh)
- Inputs: all PRD items passes=true, verify_post green, required iteration artifacts present (plans/ralph.sh)
- Outputs: .ralph/final_verify_<timestamp>.log; exit 0 when complete (plans/ralph.sh)

13) plans/workflow_contract_gate.sh (traceability gate)
- Command: ./plans/workflow_contract_gate.sh
- Inputs: specs/WORKFLOW_CONTRACT.md, plans/workflow_contract_map.json (plans/workflow_contract_gate.sh)
- Outputs: stdout "workflow contract gate: OK" (exit 0) or stderr with missing/extra rule ids (exit 1)

14) plans/workflow_acceptance.sh (acceptance harness)
- Command: ./plans/workflow_acceptance.sh
- Inputs: plans/ralph.sh, plans/verify.sh, plans/prd_schema_check.sh, plans/contract_review_validate.sh, plans/workflow_contract_gate.sh, plans/workflow_contract_map.json, git (worktree) (plans/workflow_acceptance.sh)
- Outputs (in worktree): .ralph/workflow_acceptance_*/.ralph/stubs/* (stub scripts), .ralph/blocked_* artifacts, .ralph/test*.log (plans/workflow_acceptance.sh)
- Cleanup: removes worktree at exit (plans/workflow_acceptance.sh)
