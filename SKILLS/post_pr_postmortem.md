# SKILL: Post-PR Postmortem (TOC + Evidence + Compounding)

## Purpose
Produce a deterministic, auditable PR postmortem that:
1) proves contract/plan compliance (evidence),
2) identifies the constraint (TOC),
3) converts learnings into enforceable workflow upgrades (AGENTS.md + elevation plan).

## Inputs
- PR diff (or list of changed files)
- CONTRACT.md (canonical) and/or CR-ID list
- IMPLEMENTATION_PLAN.md (if relevant)
- Verification outputs/log paths (plans/verify.sh, workflow_acceptance.sh, artifacts.json, etc.)

## Output
Fill the PR template sections 0–14 with:
- concrete commands + key output lines,
- contract anchors/CR-IDs,
- 1–3 AGENTS.md bullets (trigger + prevents + enforce),
- elevation plan (1 permanent fix + 2 cheap wins) tied to top sinks.

## Non-Negotiables
- NO vague proof. "Passed" must include command + 1–3 key lines + artifact/log path.
- NO new systems. If proposing tooling, it must directly reduce an identified sink or prevent a failure mode.
- NO more than 3 AGENTS.md bullets. Each must be enforceable (script/test/checklist).
- If you changed a contract/map pair (or similar coupled artifacts), explicitly call it out in "split-brain/drift check".

## Procedure
### Step 1 — Requirements Index (local to this PR)
1. Identify the MUST/SHALL requirements touched.
2. Record them as CR-IDs or contract anchors (Section/Heading + anchor/line if available).
3. If you can’t cite: mark UNPROVEN and do not claim compliance.

### Step 2 — Evidence Pack
1. List the exact verification commands you ran.
2. For each, capture:
   - command line,
   - 1–3 key output lines (not full logs),
   - artifact/log file path(s).
3. If you reran tests: state why (what changed).

### Step 3 — Constraint (TOC)
1. Name ONE constraint that dominated cycle time or risk.
2. Exploit: what you did in this PR to mitigate (band-aid is OK).
3. Subordinate: what the workflow/other agents must do next time.
4. Elevate: permanent fix that removes the constraint.

### Step 4 — Assumptions
List every assumption that affected design decisions:
- Assumption -> where it should be proven -> validated? (Y/N)

### Step 5 — Friction Telemetry
Rank top 3 sinks:
- name the script/test/step,
- say why it consumed time/tokens,
- link it to the Elevate/Subordinate plan.

### Step 6 — Failure Modes
If anything failed:
- repro steps,
- root cause,
- fix,
- prevention (a check/test/gate).

### Step 7 — Merge Conflict Control (Change Zoning)
1. List changed files.
2. Identify hot zones (files/sections likely to collide).
3. State what future agents should avoid or coordinate on.

### Step 8 — Compounding Improvements (the money step)
#### 8a) AGENTS.md bullets (1–3)
For each bullet:
- Rule (MUST/SHOULD),
- Trigger condition,
- Failure mode prevented,
- Where enforced (script/test/checklist).

#### 8b) Elevation plan (tie to sinks)
Provide:
- 1 Elevation (permanent fix),
- 2 Subordinate cheap wins,
Each with:
- Owner,
- Effort (S/M/L),
- Expected gain,
- Proof of completion (what objective evidence shows it’s done).

## Stop Conditions
Mark the PR as BLOCKED if any are true:
- You can’t cite the requirement you claim to satisfy.
- You introduced a second source of truth or duplicated rule without consolidation.
- Evidence is missing for required verifications.
- The “Compounding Improvements” section is empty or non-enforceable.

## Quality Bar (what “good” looks like)
- Someone unfamiliar with the PR can reproduce proof in <5 minutes.
- Next agent can avoid your failure mode using a single AGENTS.md bullet.
- Your elevation plan clearly reduces the top sinks, not random “nice to haves”.
