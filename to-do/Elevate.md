1. ==**workflow acceptance self-check==**
**Outcome & Scope**

- Contract change first: document dependency-eligibility block reasons in `specs/WORKFLOW_CONTRACT.md` and keep WF IDs synchronized.
- Add a workflow acceptance self-check that fails when fixture files referenced in tests are not listed in the overlay set.
- Add a small dependency‑fixture helper in `plans/workflow_acceptance.sh` and use it in at least one dependency test.
- Non-goals: no changes to `plans/ralph.sh` selection logic, no PRD schema changes, no new external tooling.

**Design Sketch (Minimal)**

- Add a helper in `plans/workflow_acceptance.sh` to generate dependency PRD fixtures (inline JSON) for ad hoc tests.
- Add a fixture overlay audit in `plans/workflow_acceptance.sh` that:
    - extracts `plans/fixtures/...` references from the acceptance script,
    - verifies each referenced fixture is present in `OVERLAY_FILES` (or in optional overlays if the file exists),
    - fails early with a clear message if any are missing.
- Update `specs/WORKFLOW_CONTRACT.md` to explicitly enumerate dependency block reasons and unsatisfied dependency statuses; if a new WF-* rule is added, update `plans/workflow_contract_map.json` accordingly.

**Change List (Patch Plan)**

1. **Contract update**
    
    - Edit `specs/WORKFLOW_CONTRACT.md` near §5.3 (Selection modes) or §6.2 (Blocked artifacts).
    - Add a short “Dependency eligibility block reasons” subsection listing:
        - `missing_dependency_id` (any active-slice candidate references a missing PRD ID → blocked).
        - `dependency_deadlock` (no eligible items in ACTIVE_SLICE).
        - `dependency_deadlock.json` unsatisfied dependency statuses: `missing_dependency_id`, `blocked_by_human_decision`, `unsatisfied_not_passed`.
    - If you add a new WF-* rule ID (recommended for enforceability), update `plans/workflow_contract_map.json`with enforcement + acceptance test reference.
2. **Workflow acceptance: fixture overlay self-check**
    
    - Edit `plans/workflow_acceptance.sh` near overlay setup.
    - Add a helper to collect fixture references from the script (regex for `plans/fixtures/[^\"'[:space:]]+`).
    - Add a new test (e.g., “Test 0h: fixture overlays include referenced fixtures”) that compares references to overlay lists and fails on missing overlays.
3. **Workflow acceptance: dependency fixture helper**
    
    - Add a short helper (e.g., `write_dependency_fixture <path> <mode>`) that writes a PRD JSON with dependency scenarios (order, cycle, missing).
    - Use the helper in at least one dependency-related test (suggested: replace Test 15d cycle fixture with a generated file under `.ralph/`).

**Tests & Proof**

- Fast sanity:
    - `bash -n plans/workflow_acceptance.sh`
- Required full gate (mandatory because `plans/workflow_acceptance.sh` changes):
    - `./plans/verify.sh full`

**Failure Modes & Rollback**

- False positives in fixture scan (regex grabs non-fixture strings) → tighten regex or scope to `plans/fixtures/`.
- Helper writes invalid PRD → acceptance tests fail; fix JSON schema in helper.
- New WF-* rule not mapped → `plans/workflow_contract_gate.sh` fails in verify.
- Rollback: revert edits to `specs/WORKFLOW_CONTRACT.md`, `plans/workflow_acceptance.sh`, and `plans/workflow_contract_map.json` together.

**Merge-Conflict Controls**

- Hot zones: `specs/WORKFLOW_CONTRACT.md`, `plans/workflow_acceptance.sh`, `plans/workflow_contract_map.json`.
- Keep edits localized to small sections; avoid reformatting or unrelated changes.

**Acceptance Criteria (Definition of Done)**

- `specs/WORKFLOW_CONTRACT.md` explicitly documents dependency eligibility block reasons and statuses.
- `plans/workflow_acceptance.sh` fails when a referenced fixture path is not included in overlays.
- A new dependency‑fixture helper exists and is used in at least one test.
- `plans/workflow_contract_map.json` is updated if any new WF-* rule ID is introduced.
- `./plans/verify.sh full` passes.





2. ==Full 2 Quick==

**Outcome & Scope**

- **Outcome:** Workflow acceptance enforces the CI-aware default mode for `plans/verify.sh`, with proof via `./plans/verify.sh full`; no trading-contract changes.
- **Non-goals:** No changes to trading logic, PRD items, or verify mode behavior beyond validation/documentation.

**Design Sketch (Minimal)**

- **Mechanism:** Add/strengthen a workflow-acceptance assertion that parses the default-mode block in `plans/verify.sh` and confirms CI ⇒ `MODE="full"` and non-CI ⇒ `MODE="quick"` when no arg is provided; keep it static (no heavy verify runs).

**Change List (Patch Plan)**

- **Step 1:** Update the existing “default mode” check in `plans/workflow_acceptance.sh` (near the current awk block) to a stricter CI-aware assertion that matches the `CI` branch and the `MODE="full"/"quick"` assignments in order.
- **Step 2:** Confirm `plans/verify.sh` header notes the CI-aware default (already present); update only if missing.
- **Step 3:** Confirm `AGENTS.md` includes the new rule about verify default changes needing acceptance coverage (already added); update only if missing.

**Tests & Proof**

- **Fast check:** `./plans/workflow_acceptance.sh` (to validate the new assertion directly).
- **Required gate:** `./plans/verify.sh full` (mandatory because workflow acceptance was touched).

**Failure Modes & Rollback**

- **Over‑strict parsing:** Assertion fails after innocuous refactors; detect via workflow acceptance failure; rollback by loosening the pattern or anchoring on a small explicit marker in `plans/verify.sh`.
- **False positives:** Assertion passes even if default logic drifts; detect in review; fix by tightening the awk to enforce branch structure (CI branch and else branch).
- **Doc mismatch:** Header note missing; detect via review or optional check; rollback by adding the single-line comment.

**Merge‑Conflict Controls**

- **Hot zone:** `plans/workflow_acceptance.sh` mid‑file verify checks; keep edits tightly scoped to the default‑mode assertion block to minimize conflicts.

**Acceptance Criteria (Definition of Done)**

- **Must:** `plans/workflow_acceptance.sh` contains a CI‑aware default‑mode assertion that enforces CI ⇒ full, non‑CI ⇒ quick.
- **Must:** `./plans/verify.sh full` passes.
- **Must:** `plans/verify.sh` header documents the CI‑aware default (if not already).
- **Must:** `AGENTS.md` rule about verify default changes + acceptance coverage exists (if not already).



3. ==Verbose vs quiete== 
- Add a new workflow rule under §5.5 (e.g., `WF-5.5.2`) in `specs/WORKFLOW_CONTRACT.md` stating that `plans/verify.sh` must support `VERIFY_CONSOLE=auto|quiet|verbose`, default `auto` → `quiet` in CI, and in quiet mode must print a failure tail + grep summary controlled by `VERIFY_FAIL_TAIL_LINES` and `VERIFY_FAIL_SUMMARY_LINES`.
- Add the matching rule entry to `plans/workflow_contract_map.json` with enforcement in `plans/verify.sh` and tests in `plans/workflow_acceptance.sh`.

**Outcome & Scope**

- `plans/verify.sh` documents and honors quiet/verbose console modes and failure excerpts (tail + summary) with tunable knobs.
- Workflow acceptance enforces the presence and wiring of these quiet-mode behaviors.
- Non-goals: change Ralph output discipline; alter root `verify.sh`; change CI configs; add new tools.

**Design Sketch**

- `plans/verify.sh` uses `VERIFY_CONSOLE` to choose verbose vs quiet; quiet always captures logs and calls `emit_fail_excerpt`.
- `emit_fail_excerpt` uses `VERIFY_FAIL_TAIL_LINES` and `VERIFY_FAIL_SUMMARY_LINES` to show concise failure context.
- `plans/workflow_acceptance.sh` adds static checks (grep/awk) to assert the quiet-mode wiring and header docs are present and consistent.

**Change List (patch plan)**

- `specs/WORKFLOW_CONTRACT.md`: add `WF-5.5.2` text under verify gates/output discipline describing `VERIFY_CONSOLE` and excerpt knobs.
- `plans/workflow_contract_map.json`: add `WF-5.5.2` mapping to `plans/verify.sh` and the new acceptance test location.
- `plans/verify.sh`:
    - Ensure the header “Logging/timeouts” block lists `VERIFY_CONSOLE`, `VERIFY_FAIL_TAIL_LINES`, `VERIFY_FAIL_SUMMARY_LINES`.
    - Ensure quiet mode path calls `emit_fail_excerpt` and that `emit_fail_excerpt` reads both env knobs.
- `plans/workflow_acceptance.sh`:
    - Add a test block near the existing verify.sh checks to assert:
        - header includes the `VERIFY_CONSOLE` and fail-excerpt knobs,
        - `VERIFY_CONSOLE=auto` selects quiet in CI (via `is_ci` branch),
        - `emit_fail_excerpt` is called in the quiet-mode branch,
        - the grep summary pattern includes `error:|FAIL|FAILED|panicked`.
- `reviews/postmortems/*`: add a postmortem entry from `reviews/postmortems/PR_POSTMORTEM_TEMPLATE.md`(required for verify).
- If this elevation corresponds to a tracked friction item, update `WORKFLOW_FRICTION.md` (Active/Resolved) with the elevation action.

**Tests & Proof**

- Run:

```
./plans/verify.sh full
```

- Expected: workflow acceptance passes; verify quiet-mode checks present; verify returns 0.

**Failure Modes & Rollback**

- New WF rule added but map not updated → workflow contract gate fails; rollback by syncing `plans/workflow_contract_map.json` or reverting the WF rule.
- Acceptance grep/awk too brittle → workflow acceptance fails; rollback by loosening pattern or moving checks next to existing verify.sh checks.
- Header docs drift from behavior → acceptance fails; rollback by re-aligning header text with actual env var usage.

**Merge-Conflict Controls**

- Hot zones: `specs/WORKFLOW_CONTRACT.md`, `plans/workflow_contract_map.json`, `plans/verify.sh`, `plans/workflow_acceptance.sh`.
- Minimize conflicts by appending the new WF rule near existing §5.5 content, and placing the new acceptance checks adjacent to the current verify.sh grep checks.

**Acceptance Criteria (Definition of Done)**

- `specs/WORKFLOW_CONTRACT.md` includes `WF-5.5.2` (or equivalent) for verify quiet mode + excerpts.
- `plans/workflow_contract_map.json` includes the new WF rule and test mapping.
- `plans/verify.sh` header documents `VERIFY_CONSOLE`, `VERIFY_FAIL_TAIL_LINES`, `VERIFY_FAIL_SUMMARY_LINES`, and quiet mode uses them.
- `plans/workflow_acceptance.sh` enforces the quiet-mode wiring and header docs.
- `./plans/verify.sh full` passes (includes workflow acceptance).






4. ==4 builtins==

- After change, workflow acceptance fails fast if harness scripts use bash 4+ builtins (`mapfile`, `readarray`).
- After change, AGENTS.md documents bash 3.2 compatibility for harness scripts and acceptance selector behavior is guarded by a dedicated test.
- Non-goals: no changes to trading logic, no changes to PRD items, no changes to CI pipelines beyond existing workflow acceptance gates.

2. Design sketch (minimal)

- Add a workflow acceptance test that scans relevant harness scripts for `mapfile|readarray` usage and fails.
- Add a new acceptance test covering `--from/--until` selection in `plans/workflow_acceptance.sh` to ensure selector behavior stays stable.
- Add AGENTS.md guidance for bash 3.2 compatibility so the rule is discoverable and enforced by acceptance.

3. Change List (patch plan)

- `AGENTS.md`
    - Add a MUST rule: “Harness scripts must remain bash 3.2 compatible; avoid bash 4+ builtins like mapfile/readarray.”
    - Keep wording consistent with existing “Harness guardrails” section.
- `plans/workflow_acceptance.sh`
    - Add a new test (new ID) under the 0x workflow preflight section that:
        - Scans harness scripts (see allowlist in `plans/verify.sh:is_workflow_file` + harness scripts under `plans/`) for `mapfile` or `readarray`.
        - Fails with a clear message listing offending file(s).
    - Add a new test (new ID) to exercise `--from`/`--until` selection (e.g., run `--from 0h --until 0i` and assert that only 0h/0i run).
    - Ensure test IDs are stable and listable (no dynamic generation).
    - Keep logic bash 3.2 compatible (no arrays that require bash 4 features).

4. Tests & Proof

- Fast checks:
    - `bash -n plans/workflow_acceptance.sh`
    - `./plans/workflow_acceptance.sh --list` (confirm new IDs listed)
    - `./plans/workflow_acceptance.sh --only <new_bash_guard_id>`
    - `./plans/workflow_acceptance.sh --only <new_selector_id>`
- Full gates:
    - `./plans/verify.sh full`
- Expected signals:
    - New acceptance test fails if any harness script contains `mapfile`/`readarray`.
    - Selector test runs only the specified range and exits 0.

5. Failure Modes & Rollback

- Failure: false positives from grep pattern matching in non-harness files.
    - Detection: acceptance test fails on clean repo.
    - Rollback: tighten file list to explicit harness scripts.
- Failure: selector test is brittle due to ordering changes of existing IDs.
    - Detection: acceptance test fails after ID reordering.
    - Rollback: use named IDs and validate inclusion rather than hardcoded index.
- Failure: acceptance changes require full verify and are skipped.
    - Detection: verify gate fails in CI due to missing acceptance proof.
    - Rollback: rerun `./plans/verify.sh full` after patch; no code rollback.

6. Merge-Conflict Controls

- Hot zones: `plans/workflow_acceptance.sh` (frequently edited), `AGENTS.md`.
- Minimize conflicts:
    - Append new tests near existing selector tests (0l/0m/0n) to keep grouping.
    - Keep AGENTS change localized to the harness guardrails section.
- Suggested branch name: `workflow/bash-compat-guard`.

7. Acceptance Criteria (Definition of Done)

- AGENTS.md includes a MUST rule for bash 3.2 compatibility of harness scripts.
- Workflow acceptance has a test that fails when `mapfile`/`readarray` appears in harness scripts.
- Workflow acceptance includes a test that validates `--from/--until` selection behavior.
- `./plans/verify.sh full` passes.
- Postmortem includes AGENTS.md update reference and the elevation plan per template.