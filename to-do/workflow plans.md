# Plan 1 — Run workflow_acceptance only when workflow/harness files change (CI + local)
Status: NOT IMPLEMENTED

## Elevation (approved fix)

Stop running **workflow acceptance** for every Stoic Trader story. Run `workflow_acceptance.sh` **only when workflow/harness files change**, while keeping `verify.sh` as the always-on “mergeable green” gate.

### Context (brief)

Your workflow contract already distinguishes **workflow maintenance tasks** from PRD stories and says maintenance tasks are governed by change control (and still must verify) — meaning workflow acceptance doesn’t need to run on every product story.

WORKFLOW_CONTRACT

### Repo pointers

- `plans/workflow_acceptance.sh`
    
    workflow_acceptance
    
- `plans/verify.sh`
    
    verify
    
- CI config: `.github/workflows/*` (or your equivalent CI entrypoints)
    

### Constraints (scope fence)

- Must **not** weaken fail-closed workflow rules (verification mandatory, contract alignment).
    
    WORKFLOW_CONTRACT
    
- Must keep `plans/verify.sh` as canonical verification entrypoint (contract requires it).
    
- Must preserve ability to **force-run** workflow acceptance.
    

---

## 1) Outcome & Scope

- CI always runs `./plans/verify.sh full` (or equivalent) for _all_ PRs/commits.
    
- CI runs `./plans/workflow_acceptance.sh full` **only when workflow/harness files changed** (or when manually forced).
    

**Non-goals**

- Do not redesign Ralph loop or PRD schema.
    
- Do not remove acceptance tests—only change _when they execute_.
    

---

## 2) Design sketch (minimal)

**Key mechanism:** “workflow-changed detector” used by CI and optionally by local scripts.

**Data flow:**

1. Detector compares `BASE_REF...HEAD` changed files.
    
2. If any file matches “workflow zone” patterns → run workflow acceptance.
    
3. Otherwise → skip acceptance (exit 0) with a clear “SKIP” message.
    

**Public interfaces impacted**

- CI workflow config (paths filter or conditional step).
    
- Optional: `workflow_acceptance.sh` adds `--auto-skip` behavior.
    

---

## 3) Change List (patch plan)

1. **Add a workflow-changed detector script**
    
    - **Add file:** `plans/workflow_changed.sh`
        
    - **Add objects:**
        
        - `WORKFLOW_PATH_PATTERNS` (array or regex list)
            
        - `BASE_REF` handling (default `origin/main`, overridable)
            
        - exit codes:
            
            - `0` = workflow changed (run acceptance)
                
            - `1` = no workflow change (skip)
                
    - **Backward compatibility:** new file only
        
2. **Update CI to conditionally run workflow acceptance**
    
    - **Edit:** `.github/workflows/<ci>.yml` (or add new workflow file)
        
    - **Add logic (choose one):**
        
        - **Paths filter:** job triggers only on workflow paths
            
        - **Conditional step:** run `plans/workflow_changed.sh` then gate acceptance step on its exit code
            
    - **Backward compatibility:** does not affect local dev
        
3. **(Optional but recommended) Add “force” and “auto” behavior to workflow_acceptance**
    
    - **Edit:** `plans/workflow_acceptance.sh`
        
    - **Add env flags:**
        
        - `WORKFLOW_ACCEPTANCE_FORCE=1` → always run
            
        - `WORKFLOW_ACCEPTANCE_AUTO=1` → run detector first; skip if no workflow changes
            
    - **Backward compatibility:** default behavior unchanged unless env vars set
        

---

## 4) Tests & Proof

**Fast checks**

- `bash -n plans/workflow_changed.sh`
    
- `BASE_REF=HEAD~1 ./plans/workflow_changed.sh` (should be deterministic on local branch)
    

**Full gate checks**

- Product-only change PR:
    
    - CI runs `./plans/verify.sh full`
        
    - CI **skips** `./plans/workflow_acceptance.sh`
        
- Workflow change PR (modify `plans/verify.sh` or `plans/ralph.sh`):
    
    - CI runs both `verify.sh` and `workflow_acceptance.sh full`
        

**Expected signals**

- Skip prints: `SKIP: no workflow/harness changes detected`
    
- Run prints the normal `workflow_acceptance` test output.
    

---

## 5) Failure Modes & Rollback

1. **False negative:** workflow change not detected → acceptance skipped incorrectly
    
    - Detect via: workflow bug slips through; acceptance didn’t run
        
    - Rollback: widen patterns; force-run acceptance temporarily
        
2. **False positive:** acceptance runs too often
    
    - Detect via: acceptance runs on product-only changes
        
    - Rollback: tighten patterns
        
3. **BASE_REF missing in CI** (shallow checkout)
    
    - Detect via: detector fails to diff
        
    - Rollback: use CI-native “changed files” action or fetch default branch
        

---

## 6) Merge-Conflict Controls

**Hot zones**

- `.github/workflows/*`
    
- `plans/workflow_acceptance.sh`
    

**Minimize conflicts**

- Add new script file (low conflict)
    
- Keep acceptance script change limited to a small “auto-skip” preamble
    

**Branch naming**

- `wf/ci-skip-workflow-acceptance-when-unchanged`
    

---

## 7) Acceptance Criteria (Definition of Done)

-  Workflow acceptance runs in CI **only** when workflow/harness files change (or forced).
    
-  Product story PRs still run `./plans/verify.sh full` in CI.
    
-  A workflow change PR demonstrably triggers acceptance.
    
-  No fail-open behavior introduced.
    

---

# Plan 2 — Add “smoke” mode to workflow_acceptance.sh for fast iteration
Status: NOT IMPLEMENTED

## Elevation (approved fix)

Add a **smoke mode** to `workflow_acceptance.sh` so workflow tweaks can be validated quickly locally, while CI still runs the full suite.

### Context

`workflow_acceptance.sh` is intentionally comprehensive and runs many Ralph-loop simulations. It’s valuable, but too expensive to run for every small workflow iteration.

workflow_acceptance

### Repo pointers

- `plans/workflow_acceptance.sh`
    
    workflow_acceptance
    

### Constraints

- Full suite remains available and is still the CI standard for workflow changes.
    
- Smoke suite must include the **most failure-prone invariants** (schema/lint/traceability + at least 1 harness run).
    

---

## 1) Outcome & Scope

- `./plans/workflow_acceptance.sh smoke` runs a **subset** (fast) and exits 0/1 deterministically.
    
- `./plans/workflow_acceptance.sh full` keeps current behavior (default).
    

**Non-goals**

- Don’t rewrite the entire file into a new framework.
    
- Don’t remove existing tests.
    

---

## 2) Design sketch (minimal)

**Mechanism:** Argument-based early exit after a “core invariant” checkpoint.

**Data flow**

- Run overlay setup (already required)
    
- Run:
    
    - PRD schema/lint/ref checks (already early)
        
    - Verify script invariants checks (grep-based checks you already do)
        
    - Workflow traceability gate: `./plans/workflow_contract_gate.sh`
        
    - 1 minimal Ralph dry-run sanity (optional but recommended)
        
- If smoke → exit 0 with message
    
- Else → continue running the full existing suite
    

**Public interfaces impacted**

- CLI usage: `workflow_acceptance.sh [smoke|full]`
    

---

## 3) Change List (patch plan)

1. **Add mode parsing at top**
    
    - **Edit:** `plans/workflow_acceptance.sh`
        
    - **Add objects:**
        
        - `MODE="${1:-full}"`
            
        - validate `MODE in {smoke,full}`
            
        - `shift || true` to allow future args
            
2. **Move/duplicate the traceability gate earlier**
    
    - **Edit:** `plans/workflow_acceptance.sh`
        
    - **Add step (early):**
        
        - `run_in_worktree ./plans/workflow_contract_gate.sh >/dev/null 2>&1`
            
    - **Why:** traceability is valuable even in smoke mode
        
3. **Add a smoke exit checkpoint**
    
    - **Edit:** `plans/workflow_acceptance.sh`
        
    - **Insert after the early invariant checks (+ traceability):**
        
        - `if [[ "$MODE" == "smoke" ]]; then echo "Workflow acceptance smoke tests passed"; exit 0; fi`
            
    - **Backward compatibility:** `full` continues unchanged
        

---

## 4) Tests & Proof

**Fast checks**

- `bash -n plans/workflow_acceptance.sh`
    
- `./plans/workflow_acceptance.sh smoke` exits 0 on clean repo
    

**Full gate checks**

- `./plans/workflow_acceptance.sh full` matches current behavior and passes
    

**Expected signals**

- Smoke prints: `Workflow acceptance smoke tests passed`
    
- Full prints: `Workflow acceptance tests passed`
    

---

## 5) Failure Modes & Rollback

1. Smoke misses a regression that full would catch
    
    - Detect via: CI full failing on workflow PR
        
    - Rollback: expand smoke checkpoint to include the missing test(s)
        
2. Smoke accidentally exits before running essential checks
    
    - Detect via: smoke passes even with obviously broken PRD schema
        
    - Rollback: reposition smoke exit later
        
3. CLI misuse
    
    - Detect via: unknown mode
        
    - Rollback: strict mode validation + `--help` output
        

---

## 6) Merge-Conflict Controls

**Hot zone**

- `plans/workflow_acceptance.sh` (large file)
    

**Minimize conflicts**

- Only add:
    
    - mode parsing block near top
        
    - one early call to traceability gate
        
    - one `if smoke exit` checkpoint
        

**Branch naming**

- `wf/workflow-acceptance-smoke-mode`
    

---

## 7) Acceptance Criteria (Definition of Done)

-  `workflow_acceptance.sh smoke` exists and is meaningfully faster than full.
    
-  `workflow_acceptance.sh full` behavior unchanged.
    
-  Smoke includes: PRD schema/lint + verify invariants + workflow traceability gate.
    

---

# Plan 3 — Make verify.sh “fail-safe by default” in CI (full in CI, quick locally)
Status: NOT IMPLEMENTED

## Elevation (approved fix)

Make `verify.sh` default mode **safe and predictable**: **full** when `CI=1`, **quick** otherwise, so CI cannot accidentally run a weak gate.

### Context

Your header comment says full is CI-grade, but the script currently defaults to `quick` when no args are given. This is a “footgun” in CI.

verify

### Repo pointers

- `plans/verify.sh`
    
    verify
    
- `CONTRACT.md` requires `plans/verify.sh` as canonical entrypoint.
    
    CONTRACT
    

### Constraints

- Must continue running `cargo test --workspace` (contract requirement).
    
- Must keep existing modes: quick/full/promotion.
    

---

## 1) Outcome & Scope

- In CI, calling `./plans/verify.sh` with no args runs **full**.
    
- Locally, calling `./plans/verify.sh` with no args runs **quick** (current behavior).
    

**Non-goals**

- Don’t change which checks exist—only default selection behavior.
    
- Don’t change CI_GATES_SOURCE behavior.
    

---

## 2) Design sketch (minimal)

**Mechanism:** Determine default mode based on presence of `CI`.

Pseudo-flow:

- If arg provided → respect it
    
- Else if `CI` set → `MODE=full`
    
- Else → `MODE=quick`
    

**Public interfaces impacted**

- Behavior of “no-arg” invocation only.
    

---

## 3) Change List (patch plan)

1. **Adjust mode selection**
    
    - **Edit:** `plans/verify.sh`
        
    - **Modify object:**
        
        - Replace: `MODE="${1:-quick}"`
            
        - With logic:
            
            - if `$1` is set → use it
                
            - else if `CI` set → full
                
            - else → quick
                
2. **Update top-of-file docs**
    
    - **Edit:** `plans/verify.sh`
        
    - Clarify defaults accurately
        
3. **(Optional) Add CI guardrail**
    
    - If `CI=1` and `MODE=quick` explicitly requested:
        
        - either warn loudly or fail (recommend **fail** to be truly fail-safe)
            

---

## 4) Tests & Proof

**Fast checks**

- `bash -n plans/verify.sh`
    

**Full gate checks**

- Local: `./plans/verify.sh` prints `mode=quick ...`
    
- CI simulated: `CI=1 ./plans/verify.sh` prints `mode=full ...`
    

**Expected signals**

- First line still prints `VERIFY_SH_SHA=...` (required by workflow contract checks).
    
    verify
    

---

## 5) Failure Modes & Rollback

1. CI unexpectedly relied on quick mode
    
    - Detect via: CI runtime increase
        
    - Rollback: allow explicit quick mode only on non-protected branches (policy), or allow override env var
        
2. Someone’s local workflow gets slower
    
    - Detect via: local no-arg now full (should not happen with this design)
        
    - Rollback: fix mode detection
        
3. Promotion mode confusion
    
    - Detect via: promotion doesn’t set VERIFY_MODE
        
    - Rollback: keep existing promotion alias intact
        

---

## 6) Merge-Conflict Controls

**Hot zone**

- `plans/verify.sh`
    

**Minimize conflicts**

- Limit edits to the MODE assignment block + comment updates
    

**Branch naming**

- `wf/verify-default-full-in-ci`
    

---

## 7) Acceptance Criteria (Definition of Done)

-  `CI=1 ./plans/verify.sh` runs full mode without requiring args.
    
-  Local `./plans/verify.sh` remains quick by default.
    
-  Contract-required gates remain (workspace test still present).
    

---

# Plan 4 — Make the endpoint gate base-ref robust (less CI friction, fewer false fails)
Status: NOT IMPLEMENTED

## Elevation (approved fix)

Improve endpoint gate base-ref selection so it works reliably in PR CI (base branch might not be `main`) and doesn’t fail due to shallow fetch assumptions.

### Context

Your endpoint gate is excellent for enforcing “endpoint changes require tests,” but `BASE_REF=origin/main` can break on repos whose default branch differs or on PR base branches.

verify

### Repo pointers

- `plans/verify.sh` endpoint gate section
    
    verify
    
- CI checkout settings (fetch depth)
    

### Constraints

- Must remain fail-closed in CI when it can’t diff base (that’s already your stance).
    
    verify
    
- Must keep `ENDPOINT_GATE=0` local-only bypass (ignored in CI).
    

---

## 1) Outcome & Scope

- In CI PRs, endpoint gate uses the **actual PR base branch** when available.
    
- For non-PR CI or local runs, it falls back to detected default branch.
    

**Non-goals**

- Don’t change the core policy (“endpoint-ish change must have tests”).
    
- Don’t tighten patterns yet (just base-ref reliability).
    

---

## 2) Design sketch (minimal)

**Mechanism:** Base-ref detection precedence:

1. If `BASE_REF` env set → use it
    
2. Else if GitHub Actions PR → use `origin/$GITHUB_BASE_REF`
    
3. Else if `origin/HEAD` exists → use that
    
4. Else fallback to `origin/main`
    

Ensure fetch gets the chosen base ref.

**Public interfaces impacted**

- Optional: new env var `VERIFY_BASE_REF` alias to `BASE_REF`
    

---

## 3) Change List (patch plan)

1. **Add helper to detect default branch**
    
    - **Edit:** `plans/verify.sh`
        
    - **Add function:** `detect_base_ref()`
        
        - reads `BASE_REF`, `GITHUB_BASE_REF`, `git symbolic-ref refs/remotes/origin/HEAD`
            
2. **Update endpoint gate to use detected base**
    
    - **Edit:** `plans/verify.sh`
        
    - Replace `BASE_REF="${BASE_REF:-origin/main}"` with:
        
        - `BASE_REF="$(detect_base_ref)"`
            
3. **Fetch the right base branch in CI**
    
    - **Edit:** `plans/verify.sh`
        
    - Replace hard-coded fetch of `main` with a fetch of `${BASE_REF#origin/}`
        

---

## 4) Tests & Proof

**Fast checks**

- `bash -n plans/verify.sh`
    

**Targeted checks**

- Local simulation:
    
    - `BASE_REF=HEAD~1 ./plans/verify.sh quick`
        
- CI PR:
    
    - Ensure logs show `BASE_REF=origin/<actual_base>`
        

**Expected signals**

- Endpoint gate passes on PRs where base branch is not `main`
    
- CI still fails if it truly cannot diff the base
    

---

## 5) Failure Modes & Rollback

1. Wrong base branch detected → false passes/fails
    
    - Detect via: logs show weird base ref
        
    - Rollback: force `BASE_REF` in CI, fix detect function
        
2. Fetch still too shallow
    
    - Detect via: CI fail “must be able to diff”
        
    - Rollback: set checkout to fetch-depth 0 OR fetch base branch ref explicitly
        
3. Non-GitHub CI
    
    - Detect via: env vars missing
        
    - Rollback: fallback to origin/HEAD or origin/main
        

---

## 6) Merge-Conflict Controls

**Hot zone**

- `plans/verify.sh`
    

**Minimize conflicts**

- Add helper function near endpoint gate section; keep edits localized
    

**Branch naming**

- `wf/verify-endpoint-gate-base-ref`
    

---

## 7) Acceptance Criteria (Definition of Done)

-  CI PRs use PR base branch for endpoint gate when available.
    
-  CI no longer assumes `origin/main` always exists.
    
-  Fail-closed behavior preserved when diff is impossible.
    

---

# Plan 5 — Add a “summary console mode” to verify.sh to reduce token/log volume
Status: NOT IMPLEMENTED

## Elevation (approved fix)

Add a `VERIFY_CONSOLE_MODE=summary` option so verify logs are still captured to artifacts, but console output is limited to a small tail/summary suitable for agent prompts.

### Context

`verify.sh` currently tees full command output to console (and logs). That’s great for humans but expensive for agent loops and chat-based workflows.

verify

### Repo pointers

- `plans/verify.sh`: `run_logged()` and `VERIFY_ARTIFACTS_DIR` handling
    
    verify
    

### Constraints

- Must keep `VERIFY_SH_SHA=...` first-line output (workflow contract expectation).
    
    verify
    
- Must keep full logs on disk for debugging.
    

---

## 1) Outcome & Scope

- When `VERIFY_CONSOLE_MODE=summary`, each step writes full logs to `artifacts/verify/<run_id>/*.log` but prints only:
    
    - step header
        
    - a short tail (configurable)
        
    - a grep-based error summary on failure
        

**Non-goals**

- Don’t change which checks run.
    
- Don’t remove or shrink artifacts.
    

---

## 2) Design sketch (minimal)

**Mechanism:** Modify `run_logged()` pipeline:

- `summary` mode: `tee logfile >/dev/null` then `tail -n N logfile`
    
- `full` mode: keep existing tee behavior
    

Also write `verify_summary.txt` containing:

- mode, run_id, artifact dir
    
- failing step name + extracted error lines
    

**Public interfaces impacted**

- New env vars:
    
    - `VERIFY_CONSOLE_MODE=full|summary` (default full)
        
    - `VERIFY_CONSOLE_TAIL_LINES` (default e.g. 80)
        
    - `VERIFY_SUMMARY_MAX_LINES` (default e.g. 50)
        

---

## 3) Change List (patch plan)

1. **Add console mode vars**
    
    - **Edit:** `plans/verify.sh`
        
    - **Add constants:**
        
        - `VERIFY_CONSOLE_MODE="${VERIFY_CONSOLE_MODE:-full}"`
            
        - `VERIFY_CONSOLE_TAIL_LINES="${VERIFY_CONSOLE_TAIL_LINES:-80}"`
            
        - `VERIFY_SUMMARY_FILE="$VERIFY_ARTIFACTS_DIR/verify_summary.txt"`
            
2. **Modify `run_logged()`**
    
    - **Edit:** `plans/verify.sh`
        
    - **Change behavior:**
        
        - If `VERIFY_LOG_CAPTURE=1` and `VERIFY_CONSOLE_MODE=summary`:
            
            - `run_with_timeout ... | tee "$logfile" >/dev/null`
                
            - capture rc via `PIPESTATUS[0]`
                
            - `tail -n "$VERIFY_CONSOLE_TAIL_LINES" "$logfile"`
                
        - On failure: append key lines to `verify_summary.txt` using `grep -E "FAIL:|error:|FAILED|panicked"` with max lines
            
3. **Print a final pointer**
    
    - **Edit:** `plans/verify.sh`
        
    - End-of-run: print `summary_file=...` and `artifacts_dir=...`
        

---

## 4) Tests & Proof

**Fast checks**

- `bash -n plans/verify.sh`
    

**Targeted checks**

- `VERIFY_CONSOLE_MODE=summary ./plans/verify.sh quick`
    
    - console output is short
        
    - logs exist under `artifacts/verify/<run_id>/`
        

**Full gate checks**

- CI still runs normally (likely keep `full` mode console in CI unless you opt-in)
    

**Expected signals**

- `verify_summary.txt` exists and includes failure summary when a gate fails
    

---

## 5) Failure Modes & Rollback

1. Output becomes too quiet to debug
    
    - Detect via: hard-to-understand failures
        
    - Rollback: set default to `full`, keep summary as opt-in
        
2. PIPESTATUS mishandled → false pass/fail
    
    - Detect via: step returns nonzero but script continues
        
    - Rollback: revert `run_logged()` and re-implement carefully
        
3. Tails hide the important error lines
    
    - Detect via: tail missing the real stacktrace
        
    - Rollback: increase tail lines; improve grep summary
        

---

## 6) Merge-Conflict Controls

**Hot zone**

- `plans/verify.sh`
    

**Minimize conflicts**

- Only edit `run_logged()` and add a small var block
    

**Branch naming**

- `wf/verify-console-summary-mode`
    

---

## 7) Acceptance Criteria (Definition of Done)

-  Summary console mode limits output but preserves full logs in artifacts.
    
-  `VERIFY_SH_SHA=...` remains first output line.
    
    verify
    
-  On failure, a `verify_summary.txt` exists and is useful.
    

---

# Plan 6 — Enforce “workflow maintenance tasks are NOT PRD stories” (hard guardrail)
Status: NOT IMPLEMENTED

## Elevation (approved fix)

Add a deterministic guardrail so PRD stories cannot modify workflow/harness files (unless explicitly in a workflow-maintenance lane), preventing accidental expensive acceptance runs and keeping Stoic Trader stories clean.

### Context

Your workflow contract explicitly says workflow maintenance tasks are **not executed via PRD stories** and are governed by change control. Enforcing this mechanically avoids accidental coupling.

WORKFLOW_CONTRACT

### Repo pointers

- `plans/prd_lint.sh` (referenced by acceptance)
    
    workflow_acceptance
    
- `plans/ralph.sh` scope enforcement (also referenced by acceptance)
    
    workflow_acceptance
    
- Workflow file zones:
    
    - `plans/ralph.sh`, `plans/verify.sh`, `plans/*prd*`, `plans/*contract*`, `specs/WORKFLOW_CONTRACT.md`, etc.
        

### Constraints

- Must remain fail-closed: if PRD tries to touch workflow zone → block.
    
- Must not block normal Stoic Trader code changes.
    

---

## 1) Outcome & Scope

- PRD lint (or Ralph preflight) fails if any PRD item’s `scope.touch/create` includes workflow/harness paths.
    
- Workflow maintenance changes are handled outside PRD, per contract.
    

**Non-goals**

- Don’t redesign the PRD schema.
    
- Don’t add new categories unless needed.
    

---

## 2) Design sketch (minimal)

**Mechanism:** “workflow path denylist” checked during PRD lint:

- If any item touches those paths → fail with actionable error:
    
    - “Workflow maintenance tasks must follow §11 Change Control; do not put in PRD.”
        

**Public interfaces impacted**

- PRD lint output (error message)
    
- Possibly a single override env var for emergencies (should default off in CI)
    

---

## 3) Change List (patch plan)

1. **Add workflow-path denylist to PRD lint**
    
    - **Edit:** `plans/prd_lint.sh`
        
    - **Add objects:**
        
        - `WORKFLOW_MAINT_PATHS_REGEX` (or list)
            
        - Check across:
            
            - `.items[].scope.touch[]`
                
            - `.items[].scope.create[]`
                
        - Fail if any match
            
2. **Add a fail-closed override (optional, local-only)**
    
    - `ALLOW_WORKFLOW_TASKS_IN_PRD=1` (ignored in CI)
        
    - Only for exceptional migration periods
        
3. **(Optional) Add same guard in Ralph preflight**
    
    - **Edit:** `plans/ralph.sh`
        
    - If selected story scope includes workflow zone → block with reason `workflow_task_in_prd`
        

---

## 4) Tests & Proof

**Fast checks**

- `./plans/prd_lint.sh plans/prd.json` on a PRD that includes `plans/verify.sh` in scope → must fail
    

**Full gate checks**

- `./plans/workflow_acceptance.sh` still passes (it already exercises PRD lint early)
    
    workflow_acceptance
    

**Expected signals**

- Lint failure message clearly points to contract section and the offending path(s)
    

---

## 5) Failure Modes & Rollback

1. Denylist too broad (blocks legit product paths)
    
    - Detect via: PRD lint failing unexpectedly
        
    - Rollback: narrow regex, add tests
        
2. Denylist too narrow (workflow tasks slip in)
    
    - Detect via: workflow files modified by PRD story
        
    - Rollback: expand patterns + add regression lint test case
        
3. Override abused
    
    - Detect via: CI ignoring override (recommended)
        
    - Rollback: make override local-only and fail in CI if set
        

---

## 6) Merge-Conflict Controls

**Hot zones**

- `plans/prd_lint.sh`
    
- `plans/ralph.sh`
    

**Minimize conflicts**

- Add denylist logic as a single well-delimited block
    
- Avoid reformatting the rest of the scripts
    

**Branch naming**

- `wf/block-workflow-tasks-in-prd`
    

---

## 7) Acceptance Criteria (Definition of Done)

-  PRD lint fails if a story scope touches workflow/harness paths.
    
-  Error message instructs to use workflow maintenance change control instead.
    
    WORKFLOW_CONTRACT
    
-  Normal Stoic Trader PRD stories unaffected.
