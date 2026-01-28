# Skill: Contract Check

Purpose
- Verify code changes align with CONTRACT.md requirements.
- Catch contract violations before they reach CI.

When to use
- Before committing changes to safety-critical code (PolicyGuard, TradingMode, state machines).
- After implementing a CONTRACT.md requirement.
- When reviewing PRs that touch `crates/soldier_core/`.

Procedure
1. Identify the relevant CONTRACT.md sections for your change.
2. Run the contract check script:
   ```bash
   ./plans/contract_check.sh
   ```
3. For specific sections, grep the contract:
   ```bash
   grep -n "§2.2" specs/CONTRACT.md  # PolicyGuard section
   ```
4. Verify acceptance test coverage exists for the requirement.
5. Check that fail-closed behavior is implemented.

Checklist
- [ ] Read the relevant CONTRACT.md section(s)
- [ ] Code implements the MUST/MUST NOT requirements
- [ ] Fail-closed defaults are used (ReduceOnly when uncertain, not Active)
- [ ] Acceptance tests exist and prove causality
- [ ] No unwrap() in production paths
- [ ] Error handling follows contract error codes
- [ ] /status endpoint reflects the new state correctly

Common Contract Sections
| Section | Topic |
|---------|-------|
| §2.2 | PolicyGuard (TradingMode resolution) |
| §2.2.3 | Axis Resolver (mode_reasons) |
| §2.2.4 | Open Permission Latch |
| §3.0 | Execution layer |
| §7.0 | /status observability |

Output
- List of contract refs checked
- Pass/fail status with specific violations if any
- Evidence commands run
