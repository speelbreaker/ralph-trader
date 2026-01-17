# SKILL: /plan (Elevation -> Implementation Plan)

Purpose
Convert an approved Elevation into a handoff-ready, executable plan with minimal ambiguity and merge conflict.

Inputs (required)
- Elevation: (1-3 sentences)
- Context: PR postmortem (secs 3,6,8-12) OR brief summary
- Repo pointers: key files/paths + constraints (non-bypass gates, verify scripts, CI jobs)
- Scope fence: what must NOT change (APIs/behavior/perf/deps)

If missing: proceed using repo pointers; mark Assumptions.

Output (use these headers, in order)
0) Header
Name:
Owner/Implementer:
Branch:
Risk (low/med/high + 1 line):
Primary areas (paths):

1) Contract Changes (FIRST)
Contract changes:
(list: API/schema/events/CLI/config/UI; old->new; versioning/migration; compat)
OR: No contract changes.

2) Outcome & Scope
Outcome (true after change):
...
Non-goals:
...
Scope fence (must not change):
...

3) Assumptions / Open Questions
Assumptions:
A1...
Blocking questions (only if truly blocking):
Q1...

4) Design Sketch (minimal)
Key mechanism:
...
Data flow:
A -> B -> C
Interfaces touched:
...
Backward compatibility:
...
Risk hotspots:
...

5) Change List (Patch Plan)
Patch 1 - <title>
Goal:
Files:
...
Symbols (exact objects):
add/modify ...
Compat notes:
Gating/rollout (flag/config) if any:
Proof (fast):
cmd -> expected signal

Patch 2 - ...
(repeat; keep patches reviewable + ordered)

6) Tests & Proof (Runbook)
Fast checks:
... -> expected
Targeted tests (add/update):
test_name in file
Full gates (required):
...
Expected fail signals / likely causes:
...

7) Failure Modes & Rollback
Top 3 failure modes:
... Detection: ... Mitigation: ...
...
...
Rollback plan:
revert steps / disable flag / config rollback
data rollback (if relevant)
post-rollback verification commands

8) Merge-Conflict Controls
Hot zones:
...
Change zoning strategy:
...
Branch/ownership sequencing:
...
Churn limits:
no opportunistic refactors in hot zones

9) Acceptance Criteria (DoD)
Must meet (tied to Elevation):
...
Required commands passing:
...
Non-negotiables:
no new systems unless Elevation requires
contract changes listed first (or "No contract changes.")
exact commands included for proof
