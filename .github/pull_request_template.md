# PR Summary

## 0) One-line outcome
<!-- What changed + which contract/plan requirement(s) it satisfies. Be concrete. -->

---

# Evidence & Proof (Required)

## 1) Requirements touched
<!-- List Contract anchors or CR-IDs touched. -->
- CR / Anchor:
- CR / Anchor:

## 2) Proof (commands + key outputs)
<!-- Paste the exact commands you ran and 1–3 key lines of output per command.
     If artifacts exist (.ralph/artifacts.json, logs), include paths. -->
- Command:
  - Key output:
  - Artifact/log path:
- Command:
  - Key output:
  - Artifact/log path:

---

# TOC Postmortem (Required)

## 3) Constraint (TOC)
**Constraint encountered:**  
<!-- e.g. nondeterministic tests, contract/map drift risk, slow verify loop, merge conflicts -->

**Exploit (what I did now):**  
<!-- Immediate mitigation applied in this PR -->

**Subordinate (workflow changes needed):**  
<!-- Changes other steps/agents should make to support the exploit -->

**Elevate (permanent fix proposal):**  
<!-- The real fix that removes the constraint. No hand-waving. -->

---

# Assumptions & Risk

## 4) Guesses / Assumptions (must be explicit)
<!-- Format: Assumption -> Where it should be proven -> Validated? (Y/N) -->
- Assumption -> Proof location -> Validated?
- Assumption -> Proof location -> Validated?

## 5) Split-brain / drift check
<!-- Answer YES/NO + details -->
- Did this PR introduce/modify duplicated rules or second sources of truth? (YES/NO)
- If YES: list where and how it’s resolved.

---

# Friction Telemetry (Required)

## 6) Top 3 time/token sinks
<!-- Rank them. Be specific (which script/test/step). -->
1)
2)
3)

## 7) Failure modes hit (if any)
<!-- Repro steps + fix + prevention check/test -->
- Failure:
- Repro:
- Fix:
- Prevention:

---

# Change Zoning (Merge-Conflict Control)

## 8) Files/sections changed
<!-- Bullet list -->
- 
- 

## 9) Hot zones discovered
<!-- Files/sections that are conflict magnets -->
- 
- 

## 10) Coordination note (what next agent should avoid / coordinate on)
- 

---

# Compounding Improvements (New Questions)

## 11) What should we add to `AGENTS.md`?
<!-- Propose 1–3 bullets max.
     Each bullet MUST include: trigger condition + failure mode prevented + enforcement location (script/test/checklist). -->
- **Rule:**  
  **Trigger:**  
  **Prevents:**  
  **Enforce:**  

- **Rule:**  
  **Trigger:**  
  **Prevents:**  
  **Enforce:**  

## 12) Concrete Elevation Plan to reduce Top 3 sinks
<!-- Provide: 1 Elevation + 2 subordinate cheap wins.
     Each MUST include: Owner + Effort (S/M/L) + Expected gain + Proof of completion. -->
### Elevate (permanent fix)
- **Change:**  
- **Owner:**  
- **Effort:** S / M / L  
- **Expected gain:**  
- **Proof of completion:**  

### Subordinate (cheap wins)
1)
- **Change:**  
- **Owner:**  
- **Effort:** S / M / L  
- **Expected gain:**  
- **Proof of completion:**  

2)
- **Change:**  
- **Owner:**  
- **Effort:** S / M / L  
- **Expected gain:**  
- **Proof of completion:**  

---

# Reuse

## 13) Reusable patterns/templates created
<!-- Prompts, scripts, snippets, helpers -->
- 

## 14) Skill updates
<!-- If this PR revealed a repeatable procedure, name the skill to add/update (SKILLS/*.md). -->
- Proposed skill:
- Why it’s worth codifying (failure cost / recurrence):

Two ruthless rules to adopt with this template

No Evidence, No Merge: if section “Proof” is empty or vague, PR doesn’t ship.

No Compounding, No Merge: if sections 11–12 are empty, you’re not improving the system—just moving tickets.
