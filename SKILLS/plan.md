# SKILL: /plan (Elevation -> Implementation Plan)

## Purpose
Convert an approved Elevation (permanent fix proposal) into an executable, handoff-ready plan
that a different agent can implement with minimal ambiguity and minimal merge conflict.

## Inputs (required)
- Elevation statement (1–3 sentences)
- Context: PR postmortem (sections 3, 6, 8–12) OR a brief summary
- Repo pointers: relevant files/paths + any constraints (non-bypass gates, verify scripts)
- Constraints: what must not change (scope fence)

## Output (required sections)
1) **Outcome & Scope**
   - What will be true after this change (1–2 bullets)
   - Explicit non-goals (2–4 bullets)

2) **Design sketch (minimal)**
   - Key mechanism + data flow (no essays)
   - Public interfaces impacted (if any)

3) **Change List (patch plan)**
   - Ordered steps, each with:
     - files to edit
     - exact objects to add/modify (functions, structs, constants)
     - notes on backward compatibility

4) **Tests & Proof**
   - Fast checks first (targeted)
   - Full gate checks (e.g. ./plans/verify.sh full)
   - Expected pass/fail signals

5) **Failure Modes & Rollback**
   - Top 3 ways this can break
   - Detection
   - Rollback plan (how to revert safely)

6) **Merge-Conflict Controls**
   - Hot zones touched
   - How to minimize conflicts (change zoning)
   - Suggested branch naming / ownership

7) **Acceptance Criteria (Definition of Done)**
   - Bullet list of must-meet criteria tied to the Elevation

## Non-negotiables
- No new systems unless required by the Elevation.
- If plan requires contract changes, list them first; otherwise declare “no contract changes”.
- Provide exact commands for proof.
- If any required input is missing, make best effort using repo context; mark assumptions.
