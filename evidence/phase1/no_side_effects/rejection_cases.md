# Rejection Cases - No Side Effects

This document enumerates rejection cases covered by `test_rejected_intent_has_no_side_effects`.

## CI Links
- Gate P1-C CI row: [P1-C CI links](../ci_links.md) (fill run link when available).

## Cases

| Case | Trigger | Expected Reject Reason | Side-Effect Assertions | CI Link |
|------|---------|------------------------|------------------------|---------|
| Missing config (linked orders disabled) | Linked order intent with default `OrderTypeGuardConfig` | `Preflight(LinkedOrderTypeForbidden)` | Dispatch trace empty; record/dispatch totals remain 0 (no WAL record, no order/position/exposure changes) | [P1-C CI](../ci_links.md) |
| Invalid instrument metadata | Quantization tick size = 0 | `Quantize(InstrumentMetadataMissing)` | Dispatch trace empty; record/dispatch totals remain 0 (no WAL record, no order/position/exposure changes) | [P1-C CI](../ci_links.md) |
| Quantization too small | Raw qty < min_amount after quantization | `Quantize(TooSmallAfterQuantization)` | Dispatch trace empty; record/dispatch totals remain 0 (no WAL record, no order/position/exposure changes) | [P1-C CI](../ci_links.md) |
