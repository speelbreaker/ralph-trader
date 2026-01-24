---
name: flow-audit-loop
description: Run the ACF flow audit loop for specs/CONTRACT.md using specs/flows/ARCH_FLOWS.yaml bundles, discovery audits, and minimal contract patches. Use when asked to audit ACF-### flows, regenerate bundles, or maintain flow integrity with the cross-ref and flow checkers.
---
# Flow Audit Loop

## Overview
Run a deterministic loop for one ACF flow: bundle -> discovery audit -> patch specs/CONTRACT.md -> regenerate -> run checkers -> repeat until no findings.

## Workflow (per ACF-### flow)

### 1) Confirm flow coverage
- Ensure `specs/flows/ARCH_FLOWS.yaml` has complete `refs.sections` coverage for the flow (include `Definitions` and `Appendix A` if referenced).
- If missing, update `specs/flows/ARCH_FLOWS.yaml` first, then proceed.

### 2) Generate a fresh bundle (single paste source)
```sh
python3 scripts/extract_contract_excerpts.py \
  --contract specs/CONTRACT.md \
  --flows specs/flows/ARCH_FLOWS.yaml \
  --flow-id ACF-XXX \
  --bundle \
  --out gpt/bundle_ACF-XXX.md \
  --line-numbers
```

### 3) Run discovery audit
- Use `gpt/bundle_ACF-XXX.md` as the sole input.
- Focus on: missing fail-closed behavior, missing chokepoints/order, missing ATs, missing RejectReasonCode tokens.
- Keep findings minimal and evidence-based.

### 4) Patch specs/CONTRACT.md (minimal edits)
- Add explicit fail-closed rules for missing/unparseable inputs.
- Add new AT-### blocks where coverage is missing.
- Update RejectReasonCode registry when introducing new rejection tokens.
- Keep edits localized to the relevant section.

### 5) Regenerate bundle and run checkers
```sh
python3 scripts/extract_contract_excerpts.py \
  --contract specs/CONTRACT.md \
  --flows specs/flows/ARCH_FLOWS.yaml \
  --flow-id ACF-XXX \
  --bundle \
  --out gpt/bundle_ACF-XXX.md \
  --line-numbers

python3 scripts/check_contract_crossrefs.py --contract specs/CONTRACT.md --strict --check-at --include-bare-section-refs
python3 scripts/check_arch_flows.py --contract specs/CONTRACT.md --flows specs/flows/ARCH_FLOWS.yaml --strict
```

### 6) Repeat until clean
- If the audit returns findings, apply patches and loop again.
- If no findings: declare “ACF-XXX audit clean.”

## AT numbering
- Pick the next unused AT id with:
```sh
rg -n "AT-\\d+" specs/CONTRACT.md | tail -n 5
```
- Use the next available number.

## Output format (audit results)
- Scorecard: step closure, ordering/chokepoints, fail-closed, contradictions, AT coverage.
- Findings: severity + evidence + minimal patch text + proposed AT (if needed).
- After fixes: confirm bundle regeneration + checker results.
