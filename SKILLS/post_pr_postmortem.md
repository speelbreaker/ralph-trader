# SKILL: Post-PR Postmortem (Human-Readable + Reproducible Proof)

Use this every time. It is written for a human reviewer first, with proof kept compact at the end.

0) What shipped (2-5 lines)
Feature/behavior:
Why now / user value:
Scope boundary (what's not included):

1) The big problem I fought (TOC constraint)
Constraint (pick ONE): <what dominated risk or cycle time>
How it showed up: (symptoms in this PR)
What I did this time (band-aid / exploit):
What the next agent should do by default (subordinate):
Permanent fix proposal (elevate): (ties to plan in section 4)

2) Where the time & tokens went (top sinks)
Rank the top 3. Be concrete (script/test/step), not vibes.

Sink: <script/test/loop>
Why it ate time/tokens:
What would have prevented it: (links to AGENTS.md bullet or fix plan item)

Sink: ...

Sink: ...

Quick telemetry (rough is OK):
Biggest tool/token spender: <e.g., test reruns / log spelunking / refactors>
# reruns / iterations: <n> + why

3) How the next agent avoids my pain
This is the "do this next time" playbook (short, actionable).

Do this first:
Avoid this trap:
If X happens, do Y:
Hot spots / merge conflict zones: <files/sections likely to collide>
Split-brain / drift check (only if relevant):
If you changed coupled artifacts (contract/map/config pairs): list them and confirm they're consistent.

4) Fix plan (proposal) tied to the sinks
You must propose fixes for what cost the most time/tokens.

4a) Elevation plan (exactly 1 permanent + 2 quick wins)
Permanent fix (Elevation):
What:
Owner:
Effort: S/M/L
Expected gain: (time saved, risk reduced, fewer reruns)
Proof it's done: (objective evidence: new gate/test, CI check name, command output, artifact)

Quick win #1 (Cheap Subordinate):
Owner / Effort / Gain / Proof

Quick win #2 (Cheap Subordinate):
Owner / Effort / Gain / Proof

4b) AGENTS.md additions (max 3, enforceable)
Each bullet must be a rule with a trigger + prevention + enforcement.

MUST/SHOULD: <rule>
Trigger: <when it applies>
Prevents: <failure mode>
Enforced by: <script/test/gate/checklist path>

(Optional #2) ...

(Optional #3) ...

5) Product/feature next steps (opportunities)
This is not workflow. It's how we improve the feature itself.

Opportunity #1: <improvement>
Why it matters (perf/UX/correctness/maintainability)
Smallest next step (what to implement next)

Opportunity #2: ...

Opportunity #3: ...

(Keep this focused: 2-5 bullets. No giant roadmap.)

6) Contract & proof (compact, but real)
Requirements touched (CR-IDs / anchors):
✅ <CR-ID / anchor> -> Proof: <evidence item name/link below>
⚠️ <CR-ID / anchor> -> UNPROVEN: why / what evidence is missing

Evidence (no "passed" without this):
Command: ...
Key lines:
...
...
Logs/artifacts: path/or/link
(repeat per command)

7) Stop-condition check (PASS or BLOCKED)
Mark BLOCKED if any are true:
- A claimed requirement has no cite (CR-ID/anchor) or is UNPROVEN
- Evidence missing (no command + key lines + log/artifact path)
- You introduced a second source of truth / duplicated rule
- AGENTS.md section is empty or not enforceable

Status: PASS / BLOCKED - <one line why>

Tiny reminder (keep, don't expand)
Max 3 AGENTS.md bullets. Each must be enforceable.
No new tooling unless it kills a listed sink or prevents a failure mode.
Proof = command + 1-3 key lines + artifact/log path.
