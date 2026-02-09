# Intent Gate Ordering Invariants

## Normative Ordering Constraints

1. **Reject before persist:** If any gate or authorization rejects an OPEN intent, the system MUST NOT attempt WAL recording or any dispatch side effects.
2. **WAL before dispatch:** For any OPEN intent that is allowed, the intent MUST be recorded (RecordedBeforeDispatch) before any network dispatch attempt.
3. **Side effects after accept:** Record and dispatch side effects MUST occur only after all gates succeed; a record failure MUST block dispatch.

## Contract References

- RecordedBeforeDispatch (CSP.3)
- Enforcement rules (CSP.5.2)
- Anchor-006, VR-014
