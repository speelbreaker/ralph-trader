# Plan A v2 delta checklist

**Goal of A:** fix internal inconsistencies, canonical-path policy, and required artifacts list.

### A.1 Canonical path corrections

- Update **only** `specs/WORKFLOW_CONTRACT.md` (primary).
    
- If a root `WORKFLOW_CONTRACT.md` exists, treat it as **non-canonical**:
    
    - Either convert it to a short stub that points to `specs/WORKFLOW_CONTRACT.md`, or enforce it as a strict mirror (see A.3).
        

### A.2 WF rules / sections that must be updated (to avoid internal contract conflict)

In `specs/WORKFLOW_CONTRACT.md`:

- **Top-of-file “source of truth” language** must match reality (gates treat `specs/...` as canonical). Your current excerpt says “this file” is canonical while WF‑12.8 references `specs/...`; Plan A must eliminate that contradiction.
    
    WORKFLOW_CONTRACT
    
- **WF‑12.8** already references `specs/WORKFLOW_CONTRACT.md`. Keep it, and align everything else to it.
    
    WORKFLOW_CONTRACT
    

### A.3 Required artifacts list: mapping + gate alignment

If you add new required artifact rules under §1 (e.g., new WF‑1.7/1.8/… for scripts currently “required by preflight/gates”), you must:

- Update `plans/workflow_contract_map.json` with new WF ids.
    
- Update `plans/workflow_contract_gate.sh` only if it needs path resolution updates or improved error messaging.
    

### A.4 Preflight alignment updates (if A changes “required” vs “optional”)

If you resolve `plans/update_task.sh` from “optional” → “required” (as preflight currently enforces in WF‑5.1), then also ensure:

- `plans/ralph.sh` preflight checks match the contract requirement list.
    
    WORKFLOW_CONTRACT
    

### A.5 Acceptance tests / fixtures (make them concrete)

Add to `plans/workflow_acceptance.sh`:

- A test that **runs** `plans/workflow_contract_gate.sh` and asserts it checks `specs/WORKFLOW_CONTRACT.md` (already required by WF‑12.8).
    
    WORKFLOW_CONTRACT
    
- For “missing required scripts” scenarios:
    
    - Use a **temp git worktree** approach:
        
        - create worktree → chmod/remove the target script → run `plans/ralph.sh` preflight → assert non-zero and blocked artifact → remove worktree
            
    - This avoids dirtying the main working tree.
        

### A.6 Workflow maintenance admin (add to plan)

- Branch: `speelbreaker/workflow-contract-canonicalize`
    
- Postmortem: `reviews/postmortems/YYYY-MM-DD-workflow-contract-canonicalize.md`
    

---

# Plan C v2 delta checklist

**Goal of C:** faster verify defaults + robust verify summaries (without weakening promotion/final gates).

### C.1 Canonical contract edits

In `specs/WORKFLOW_CONTRACT.md` update **existing WF ids** (avoid new WF ids unless necessary):

- Update **WF‑5.5** (verify summary definition) to reference a summarizer script (e.g., `plans/verify_summary.sh`) instead of hardcoded grep text.
    
    WORKFLOW_CONTRACT
    
- If you change verify defaults (“fast by default for iteration”), update the “Mode separation” paragraph inside **WF‑5.5** (don’t add WF‑5.5.2 unless you really need a new id).
    
    WORKFLOW_CONTRACT
    
- Ensure you **do not break WF‑8.2**: `VERIFY_SH_SHA` must remain the first line of `verify.sh` output.
    
    WORKFLOW_CONTRACT
    

### C.2 Traceability map updates

Update `plans/workflow_contract_map.json` entries for:

- **WF‑5.5**: enforced_by includes `plans/ralph.sh` + `plans/verify_summary.sh` (new)
    
- **WF‑8.2/WF‑8.3/WF‑8.4**: enforced_by includes `plans/verify.sh` and log capture paths (if your map tracks it)
    

### C.3 Fixtures: define concrete paths

Add fixtures as files:

- `plans/fixtures/verify_logs/pytest_fail.log`
    
- `plans/fixtures/verify_logs/go_test_fail.log`
    
- `plans/fixtures/verify_logs/node_fail.log`  
    Acceptance should run:
    
- `./plans/verify_summary.sh <fixture> > /tmp/summary`
    
- Assert summary contains known “signature” lines.
    

### C.4 Acceptance updates

In `plans/workflow_acceptance.sh` add checks:

- `./plans/verify.sh fast` prints:
    
    - first line: `VERIFY_SH_SHA=...`
        
    - second line (if you add it): `VERIFY_MODE=fast`
        
- Verify logs captured by harness include the SHA line (WF‑12.7 coverage).
    
    WORKFLOW_CONTRACT
    

### C.5 Workflow maintenance admin

- Branch: `speelbreaker/verify-modes-summary`
    
- Postmortem: `reviews/postmortems/YYYY-MM-DD-verify-modes-summary.md`
    

---

# Plan D v2 delta checklist

**Goal of D:** context packing + prompt budget.

### D.1 Canonical contract edits

In `specs/WORKFLOW_CONTRACT.md` prefer editing **existing WF ids**:

- If you add a new required artifact like `context_pack.md`, do it by updating **WF‑6.1**’s required artifact list (since it’s already the canonical artifact enumerator).
    
    WORKFLOW_CONTRACT
    
- If you introduce `prompt_overflow.txt`, decide:
    
    - **Option A (recommended):** treat it as an _optional diagnostic_ (WF‑6.3) created only on truncation, so you don’t expand “required artifacts” burden.
        
    - **Option B:** add to WF‑6.1 (then acceptance must enforce always-present, which is awkward because it only exists on truncation).
        

Also update text in **WF‑5.5 Output discipline** (still within WF‑5.5) to clarify:

- prompts must not embed full verify logs; summaries + file pointers only.
    
    WORKFLOW_CONTRACT
    

### D.2 Traceability map updates

Update `plans/workflow_contract_map.json` for:

- **WF‑6.1**: new artifact (`context_pack.md`) and where it’s produced (`plans/ralph.sh`, helper script)
    
- If you modify prompt handling semantics under WF‑5.5, update **WF‑5.5** mapping too.
    

### D.3 Fixtures: define concrete approach

Add a PRD fixture designed to create a “large prompt” context:

- `plans/fixtures/prd/prompt_budget_trigger.json`
    

Acceptance should:

- Run `plans/ralph.sh` in a controlled mode (dry-run if supported) with:
    
    - `RPH_PROMPT_MAX_CHARS` set very small
        
- Assert:
    
    - `.ralph/iter_*/prompt.txt` exists and contains “TRUNCATED”
        
    - `.ralph/iter_*/prompt_overflow.txt` exists (only in this test)
        
    - `.ralph/iter_*/context_pack.md` exists (if required by WF‑6.1)
        
        WORKFLOW_CONTRACT
        

### D.4 Workflow maintenance admin

- Branch: `speelbreaker/prompt-budget-context-pack`
    
- Postmortem: `reviews/postmortems/YYYY-MM-DD-prompt-budget-context-pack.md`
    

---

# Plan E v2 delta checklist

**Goal of E:** formalize discovery stories to reduce `needs_human_decision` hard-stops.

### E.1 Canonical contract edits (avoid new WF ids if possible)

In `specs/WORKFLOW_CONTRACT.md`:

- Update **WF‑10.1** text to explicitly describe “discovery story” expectations (template + evidence output), since WF‑10.1 already mentions “split into discovery + implementation.”
    
    WORKFLOW_CONTRACT
    
- If you constrain discovery stories to docs/plans/specs scope, either:
    
    - Put it in WF‑10.1 (guidance), and optionally enforce via schema check; **or**
        
    - Add a new WF id (e.g., WF‑10.2) **only if you truly need a rule id** (then map update required).
        

### E.2 Traceability map updates

Update `plans/workflow_contract_map.json` for whichever rule you enforce:

- If enforcement is in schema check:
    
    - Update **WF‑3.3/WF‑3.5** mapping to include `plans/prd_schema_check.sh` as enforcement for discovery-category constraints.
        
- If you add WF‑10.2:
    
    - Add it to the map (mandatory) + acceptance coverage reference.
        

### E.3 Fixtures: define concrete paths

Add PRD fixtures:

- `plans/fixtures/prd/discovery_ok.json` (doc/plans/specs-only scope)
    
- `plans/fixtures/prd/discovery_bad_scope.json` (touches `src/` or other forbidden paths)
    

Acceptance should run:

- `./plans/prd_schema_check.sh` on each fixture (expect pass/fail accordingly)
    

### E.4 Workflow maintenance admin

- Branch: `speelbreaker/discovery-stories`
    
- Postmortem: `reviews/postmortems/YYYY-MM-DD-discovery-stories.md`
    

---

# Plan F v2 delta checklist

**Goal of F:** self-heal ordering so attempted diff is preserved before reset/clean.

### F.1 Canonical contract edits (no new WF id needed)

In `specs/WORKFLOW_CONTRACT.md`:

- Strengthen **WF‑5.8** text to be MUST-level ordering:
    
    - capture `.ralph/iter_*/diff.patch` + `head_before.txt` **before** reset/clean.
        
        WORKFLOW_CONTRACT
        
- Update **WF‑12.2** checklist to explicitly assert that, when self-heal triggers, evidence exists (diff.patch present and meaningful).
    
    WORKFLOW_CONTRACT
    
      
    (Stick to editing existing WF ids to avoid new-map entries.)
    

### F.2 Traceability map updates

Update `plans/workflow_contract_map.json` entries for:

- **WF‑5.8**: enforced_by includes `plans/ralph.sh` and the pre-reset artifact capture function
    
- **WF‑12.2**: acceptance coverage points to the new acceptance test block
    

### F.3 Fixtures / acceptance: make the scenario reproducible

In `plans/workflow_acceptance.sh`, implement a deterministic self-heal test using a temp worktree:

- Create a temp worktree
    
- Replace or shim `plans/verify.sh` in that worktree to:
    
    - fail on first call
        
    - pass on second call
        
- Run `RPH_SELF_HEAL=1 ./plans/ralph.sh` in that worktree
    
- Assert:
    
    - `.ralph/iter_*/diff.patch` exists **and contains the attempted change**
        
    - `.ralph/iter_*/head_before.txt` exists
        
    - `.ralph/iter_*/verify_pre_after_heal.log` exists (if you generate it)
        
        WORKFLOW_CONTRACT
        

### F.4 Workflow maintenance admin

- Branch: `speelbreaker/self-heal-artifacts`
    
- Postmortem: `reviews/postmortems/YYYY-MM-DD-self-heal-artifacts.md`