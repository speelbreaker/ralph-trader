# SKILL: /pre-commit (Safety Gate Check)

Purpose
- Run all safety checks before committing to safety-critical code.
- Catch contract violations, unwrap() usage, and fail-open patterns before they reach CI.

When to use
- Before committing changes to `crates/soldier_core/` or `crates/soldier_infra/`
- After implementing a CONTRACT.md requirement
- Before any PR that touches PolicyGuard, TradingMode, or state machines

## Checklist

### 1) Code Safety Scan
```bash
# No unwrap() in production code (exclude tests)
rg "\.unwrap\(\)" crates/ --glob '!*test*' -l

# No expect() without descriptive message
rg "\.expect\(\"[^\"]{0,10}\"\)" crates/ -l

# No silent error ignoring
rg "let _ =" crates/ --glob '!*test*' -l
```

### 2) Fail-Closed Verification
For any code that resolves TradingMode or handles uncertain states:
- [ ] Default is `ReduceOnly` or `Kill`, never `Active`
- [ ] Missing/stale inputs -> restrictive mode
- [ ] Unknown intent classification -> treated as OPEN

### 3) Contract Alignment
```bash
# Run contract cross-ref checker
python3 scripts/check_contract_crossrefs.py --contract specs/CONTRACT.md --strict --check-at

# Check arch flows
python3 scripts/check_arch_flows.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --strict
```

### 4) Acceptance Test Coverage
For new guards or rules:
- [ ] TRIP AT exists (guard activates, blocks action)
- [ ] NON-TRIP AT exists (guard doesn't activate, action proceeds)
- [ ] Both prove causality via dispatch count, reject reason, or latch reason

### 5) Commit Message
- [ ] References CONTRACT.md section if implementing a requirement
- [ ] Uses format: `<area>: <what changed>`
- [ ] First line under 72 characters

## Quick Command
```bash
# Run all checks at once
python3 scripts/check_contract_crossrefs.py --contract specs/CONTRACT.md --strict --check-at && \
python3 scripts/check_arch_flows.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --strict && \
rg "\.unwrap\(\)" crates/ --glob '!*test*' -l && echo "UNWRAP CHECK: found files above" || echo "UNWRAP CHECK: clean"
```

## Output
- Pass: All checks green, safe to commit
- Fail: List of violations with file:line references
