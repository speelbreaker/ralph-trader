# SKILL: /verify (Run Verification and Explain Failures)

Purpose
- Run the verification suite (plans/verify.sh) and interpret results.
- Explain failures in context of CONTRACT.md requirements.
- Suggest fixes for common verification failures.

When to use
- Before marking a PRD task as done
- After making changes to specs/ or plans/
- When CI verification fails and you need to understand why
- As final gate before creating a PR

## Workflow

### 1) Run Verification
```bash
# Full verification
./plans/verify.sh

# Quick mode (if available)
./plans/verify.sh --quick
```

### 2) Interpret Exit Codes
| Exit Code | Meaning |
|-----------|---------|
| 0 | All checks passed |
| 1 | General failure |
| 2 | Contract validation failure |
| 3 | Acceptance test failure |
| 4 | Workflow contract violation |

### 3) Common Failures and Fixes

#### Contract Cross-Reference Errors
```
ERROR: Section ref §X.Y not found
```
**Fix:** Check section numbering in CONTRACT.md, ensure heading exists.

```
ERROR: AT-XXX referenced but not defined
```
**Fix:** Add AT-XXX definition in the relevant section, or fix the reference.

#### Arch Flow Errors
```
ERROR: Flow ACF-XXX refs missing section
```
**Fix:** Update `specs/flows/ARCH_FLOWS.yaml` to include the section in `refs.sections`.

```
ERROR: Where path not covered by any flow
```
**Fix:** Add the path to an existing flow or create a new flow.

#### State Machine Errors
```
ERROR: Invalid state transition X -> Y
```
**Fix:** Check `specs/state_machines/` for allowed transitions, update code or spec.

#### Workflow Contract Errors
```
ERROR: Workflow gate X not satisfied
```
**Fix:** Check `specs/WORKFLOW_CONTRACT.md` for gate requirements, ensure all prerequisites met.

### 4) Deep Dive Commands

When verification fails, gather more context:
```bash
# Contract cross-refs with verbose output
python3 scripts/check_contract_crossrefs.py --contract specs/CONTRACT.md --strict --check-at --include-bare-section-refs

# Arch flows with details
python3 scripts/check_arch_flows.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --strict

# State machine check
python3 scripts/check_state_machines.py

# Global invariants
python3 scripts/check_global_invariants.py
```

### 5) MCP Tools for Investigation

Use ralph MCP tools to investigate:
```
contract_lookup("X.Y")       # Read the failing section
contract_search("AT-XXX")    # Find AT references
list_acceptance_tests()      # List all ATs
check_contract_crossrefs()   # Run crossref check
check_arch_flows()           # Run flow check
```

## Failure Resolution Checklist

- [ ] Identify which check failed (crossref, flow, state machine, workflow)
- [ ] Read the relevant CONTRACT.md section
- [ ] Determine if the failure is in code or spec
- [ ] Apply minimal fix (don't over-correct)
- [ ] Re-run verify.sh to confirm fix
- [ ] Check for cascading issues (one fix may reveal others)

## Output
- Verification result (pass/fail)
- For failures: specific error, relevant CONTRACT.md section, suggested fix
- Commands to re-verify after fix
