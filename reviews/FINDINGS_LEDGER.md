# Findings Ledger

**Purpose**: Source of truth for CONTRACT.md spec-lint findings, gaps, and remediation status.

**Ledger Rules**:
- Every finding must include CONTRACT.md evidence proving its current status (Open/Fixed).
- No new findings are added until regression is clean and all current items are evidenced.

**Priority Levels**:
- **P0**: BLOCKER - Safety-critical, blocks OPEN operations
- **P1**: MAJOR - Significant gap, affects compliance/auditability
- **P2**: MINOR - Documentation/clarity issue, no runtime impact

**Status Values**:
- **Open**: Issue identified, not yet fixed
- **In Progress**: Fix underway
- **Fixed**: Patch merged, evidence anchor confirmed
- **Won't Fix**: Intentionally deferred with rationale

---

## Active Findings

Note: Audit report findings are prefixed with `AR-` to avoid collisions with existing C-00x IDs. Additional audit batches use `AR2-`. User-supplied findings are prefixed with `USR-` for the same reason. Evidence must cite CONTRACT.md anchors.

| ID | Priority | Status | Location | Patch ID | Date Fixed | Evidence |
|----|----------|--------|----------|----------|------------|----------|
| (none) | — | — | — | — | — | — |

Merged/Dependent IDs: AR-F-006 -> AR-C-001; AR-U-001 -> AR-D-001; AR-U-002 -> AR-C-002; USR-D-001 -> USR-C-001; USR-D-002 -> USR-C-002.

---

## Resolved Findings

| ID | Priority | Status | Location | Patch ID | Date Fixed | Evidence |
|----|----------|--------|----------|----------|------------|----------|
| C-001 | P0 | Fixed | §2.2 L823 | PATCH-001 | 2026-01-19 | [A.3 L3166](specs/CONTRACT.md#L3166), [AT-132](specs/CONTRACT.md#L1156) |
| C-002 | P0 | Fixed | §2.2.2 L944 | PATCH-001 | 2026-01-19 | [A.3 L3237](specs/CONTRACT.md#L3237), [AT-105](specs/CONTRACT.md#L1050) |
| C-003 | P1 | Fixed | §3.3.1 L1423 | PATCH-001 | 2026-01-19 | [A.3 L3373](specs/CONTRACT.md#L3373), [AT-106](specs/CONTRACT.md#L1641) |
| C-004 | P1 | Fixed | §3.3.1 L1423 | PATCH-001 | 2026-01-19 | [A.3 L3379](specs/CONTRACT.md#L3379), [AT-133](specs/CONTRACT.md#L1648) |
| AR-C-001 | P0 | Fixed | §2.2.4 | — | — | [L1269](specs/CONTRACT.md#L1269), [L1300](specs/CONTRACT.md#L1300) |
| AR-C-002 | P1 | Fixed | §3.4 | — | — | [L1734](specs/CONTRACT.md#L1734), [L1776](specs/CONTRACT.md#L1776) |
| AR-D-001 | P1 | Fixed | §2.3 | — | — | [L1352](specs/CONTRACT.md#L1352) |
| AR-T-001 | P1 | Fixed | Definitions | — | — | [L53](specs/CONTRACT.md#L53) |
| AR-F-011 | P1 | Fixed | §2.3.1 | — | — | [L1381](specs/CONTRACT.md#L1381) |
| AR-F-012 | P1 | Fixed | §2.3.2 | — | — | [L1416](specs/CONTRACT.md#L1416) |
| AR2-C-001 | P0 | Fixed | §4.2 / Appendix A | — | — | [L1931](specs/CONTRACT.md#L1931), [L3426](specs/CONTRACT.md#L3426) |
| AR2-C-002 | P0 | Fixed | §7.2 | — | — | [L2662](specs/CONTRACT.md#L2662) |
| AR2-U-001 | P0 | Fixed | §5.2 / §5.3 | — | — | [L2289](specs/CONTRACT.md#L2289), [L2388](specs/CONTRACT.md#L2388) |
| AR2-C-003 | P1 | Fixed | §1.1 / §6 | — | — | [L227](specs/CONTRACT.md#L227), [L2404](specs/CONTRACT.md#L2404) |
| AR2-F-001 | P1 | Fixed | §2.2.2 | — | — | [L1023](specs/CONTRACT.md#L1023), [L1078](specs/CONTRACT.md#L1078) |
| AR-D-002 | P1 | Fixed | §2.2.2 | P1-EG-001 | 2026-01-19 | [L1019](specs/CONTRACT.md#L1019) |
| AR2-D-003 | P1 | Fixed | §1.4.3 / §2.2.3 | P1-THR-DRIFT-001 | 2026-01-19 | [L1107](specs/CONTRACT.md#L1107), [L1215](specs/CONTRACT.md#L1215) |
| AR-U-003 | P2 | Fixed | §3.1 | P2-ANE-001 | 2026-01-19 | [L1548](specs/CONTRACT.md#L1548), [L1568](specs/CONTRACT.md#L1568) |
| AR-O-002 | P2 | Fixed | §3.4 | P2-ATSTD-001 | 2026-01-19 | [L1793](specs/CONTRACT.md#L1793) |
| AR2-O-001 | P1 | Fixed | §7.0 | P1-STATUS-002 | 2026-01-19 | [L2475](specs/CONTRACT.md#L2475), [L2523](specs/CONTRACT.md#L2523) |
| USR-T-503 | P0 | Fixed | §2.2.3 | — | — | [L1257](specs/CONTRACT.md#L1257) |
| USR-C-001 | P0 | Fixed | §2.2.3 / §7.2 | — | — | [L1233](specs/CONTRACT.md#L1233), [L2680](specs/CONTRACT.md#L2680) |
| USR-C-002 | P0 | Fixed | §4.2 | — | — | [L1954](specs/CONTRACT.md#L1954) |
| USR-U-001 | P0 | Fixed | §4.2 | — | — | [L1934](specs/CONTRACT.md#L1934) |
| USR-T-602 | P1 | Fixed | §5.2 | — | — | [L2276](specs/CONTRACT.md#L2276) |
| USR-D-003 | P1 | Fixed | §4.3.2 | — | — | [L2095](specs/CONTRACT.md#L2095) |
| USR-U-002 | P1 | Fixed | §1.1 | — | — | [L227](specs/CONTRACT.md#L227) |
| USR-U-003 | P1 | Fixed | §2.3 | — | — | [L1349](specs/CONTRACT.md#L1349) |
| USR-U-601 | P1 | Fixed | §2.2.2 / §2.2.5 | P1-EG-001 | 2026-01-19 | [L1017](specs/CONTRACT.md#L1017) |
| USR-T-603 | P1 | Fixed | §8.2 | P1-TEST-AT-001 | 2026-01-19 | [L2783](specs/CONTRACT.md#L2783) |
| AR-F-007 | P1 | Fixed | §1.4.3 | — | 2026-01-20 | [L723](specs/CONTRACT.md#L723) |
| AR2-C-004 | P0 | Fixed | §1.4.3 / §2.2.3 | P0-001 | 2026-01-20 | [L720](specs/CONTRACT.md#L720) |
| AR2-C-005 | P2 | Fixed | Patch Summary / §0.0 | P2-003 | 2026-01-20 | [L10](specs/CONTRACT.md#L10), [L60](specs/CONTRACT.md#L60) |
| AR2-D-004 | P2 | Fixed | §2.3 / Appendix A | P2-001 | 2026-01-20 | [L1367](specs/CONTRACT.md#L1367), [L3128](specs/CONTRACT.md#L3128) |
| AR2-D-005 | P2 | Fixed | §7.2 / Appendix A | P2-004 | 2026-01-20 | [L2714](specs/CONTRACT.md#L2714), [L3596](specs/CONTRACT.md#L3596) |
| AR2-U-002 | P2 | Fixed | §2.3.2 | P2-002 | 2026-01-20 | [L1445](specs/CONTRACT.md#L1445), [L1481](specs/CONTRACT.md#L1481) |
| AR2-U-003 | P1 | Fixed | §1.3 / Appendix A | P1-003 | 2026-01-20 | [L506](specs/CONTRACT.md#L506), [L3447](specs/CONTRACT.md#L3447) |
| AR2-T-001 | P1 | Fixed | §7.0 /status | P1-001 | 2026-01-20 | [L2589](specs/CONTRACT.md#L2589) |
| AR2-T-002 | P1 | Fixed | §1.1 | P1-002 | 2026-01-20 | [L293](specs/CONTRACT.md#L293) |
| AR2-T-003 | P0 | Fixed | §2.2.3 | P0-002 | 2026-01-20 | [L1284](specs/CONTRACT.md#L1284) |
| AR2-T-004 | P0 | Fixed | §2.2.3 | P0-002 | 2026-01-20 | [L1291](specs/CONTRACT.md#L1291) |
| AR2-T-005 | P0 | Fixed | §2.2.1.1 | P0-002 | 2026-01-20 | [L1021](specs/CONTRACT.md#L1021) |
| AR2-T-006 | P0 | Fixed | §7.0 /status | P0-003 | 2026-01-20 | [L2609](specs/CONTRACT.md#L2609) |
| AR3-F-001 | P1 | Fixed | §2.3.2 | P1-004 | 2026-01-20 | [L1517](specs/CONTRACT.md#L1517), [L1524](specs/CONTRACT.md#L1524) |
| AR3-F-002 | P1 | Fixed | §2.2.4 / §2.2.5 | P1-004 | 2026-01-20 | [L1370](specs/CONTRACT.md#L1370), [L1387](specs/CONTRACT.md#L1387) |
| AR3-T-001 | P1 | Fixed | §7.0 | P1-005 | 2026-01-20 | [L2554](specs/CONTRACT.md#L2554), [L2609](specs/CONTRACT.md#L2609) |
| G-901 | P0 | Fixed | §2.2.1.1 | P0-003 | 2026-01-20 | [L991](specs/CONTRACT.md#L991), [L1028](specs/CONTRACT.md#L1028) |
| G-902 | P0 | Fixed | §2.2.1.1 | P0-003 | 2026-01-20 | [L992](specs/CONTRACT.md#L992), [L1035](specs/CONTRACT.md#L1035) |
| O-701 | P1 | Fixed | §7.0 /status | P1-005 | 2026-01-20 | [L1209](specs/CONTRACT.md#L1209), [L2646](specs/CONTRACT.md#L2646) |
| O-702 | P1 | Fixed | §7.0 /status | P1-005 | 2026-01-20 | [L2554](specs/CONTRACT.md#L2554), [L2616](specs/CONTRACT.md#L2616), [L2623](specs/CONTRACT.md#L2623) |
| AR3-F-003 | P1 | Fixed | §2.2.2 | P1-006 | 2026-01-20 | [L1059](specs/CONTRACT.md#L1059), [L1119](specs/CONTRACT.md#L1119) |
| AR3-T-002 | P1 | Fixed | §7.0 /status | P1-006 | 2026-01-20 | [L2559](specs/CONTRACT.md#L2559), [L2609](specs/CONTRACT.md#L2609) |
| AR3-T-003 | P1 | Fixed | §2.2.3 / §7.0 | P1-006 | 2026-01-20 | [L1182](specs/CONTRACT.md#L1182), [L2562](specs/CONTRACT.md#L2562), [L2695](specs/CONTRACT.md#L2695) |
| AR4-D-001 | P0 | Fixed | §2.3 | P0-004 | 2026-01-21 | [L1475](specs/CONTRACT.md#L1475), [AT-418](specs/CONTRACT.md#L1509) |
| AR4-D-002 | P0 | Fixed | §2.2.5 / §2.3 | P0-004 | 2026-01-21 | [L1451](specs/CONTRACT.md#L1451), [AT-119](specs/CONTRACT.md#L1523) |
| AR4-C-001 | P1 | Fixed | §7.0 / §7.1 / §8.1 | P0-004 | 2026-01-21 | [L2667](specs/CONTRACT.md#L2667), [L2880](specs/CONTRACT.md#L2880) |
| AR4-U-002 | P1 | Fixed | §7.0 /status | P0-004 | 2026-01-21 | [L2660](specs/CONTRACT.md#L2660), [AT-419](specs/CONTRACT.md#L2727) |
| AR4-U-003 | P1 | Fixed | §2.3 | P0-004 | 2026-01-21 | [L1471](specs/CONTRACT.md#L1471), [AT-420](specs/CONTRACT.md#L1516) |
| AR4-F-302 | P1 | Fixed | §1.3 | P0-004 | 2026-01-21 | [L506](specs/CONTRACT.md#L506), [AT-421](specs/CONTRACT.md#L539) |
| AR4-T-001 | P1 | Fixed | §0.Y | P1-007 | 2026-01-21 | [AT-901](specs/CONTRACT.md#L92) |
| AR4-T-002 | P1 | Fixed | §7.1 | P1-007 | 2026-01-21 | [AT-902](specs/CONTRACT.md#L2922), [AT-903](specs/CONTRACT.md#L2929), [AT-904](specs/CONTRACT.md#L2936) |
| AR4-T-003 | P1 | Fixed | §0.X | P1-008 | 2026-01-21 | [AT-905](specs/CONTRACT.md#L82) |
| AR4-C-002 | P0 | Fixed | §2.2.2 | P0-005 | 2026-01-21 | [L1102](specs/CONTRACT.md#L1102), [AT-422](specs/CONTRACT.md#L1156) |
| USR-F-001 | P0 | Fixed | §2.4.1 / §7.0 /status | P0-006 | 2026-01-21 | [L1683](specs/CONTRACT.md#L1683), [AT-906](specs/CONTRACT.md#L1714), [L2710](specs/CONTRACT.md#L2710) |
| AR5-C-001 | P0 | Fixed | §2.2.3 | P0-007 | 2026-01-21 | [L1416](specs/CONTRACT.md#L1416), [AT-931](specs/CONTRACT.md#L1463) |
| AR5-F-001 | P0 | Fixed | §1.1.1 / §2.2.6 | P0-008 | 2026-01-21 | [L353](specs/CONTRACT.md#L353), [AT-926](specs/CONTRACT.md#L386), [L1711](specs/CONTRACT.md#L1711) |
| AR5-F-002 | P0 | Fixed | §1.4.1 / §2.2.6 | P0-008 | 2026-01-21 | [L686](specs/CONTRACT.md#L686), [AT-932](specs/CONTRACT.md#L712), [L1717](specs/CONTRACT.md#L1717) |
| AR5-T-001 | P1 | Fixed | §1.1 | P0-008 | 2026-01-21 | [L400](specs/CONTRACT.md#L400), [AT-928](specs/CONTRACT.md#L393), [AT-933](specs/CONTRACT.md#L332) |
| AR5-F-003 | P0 | Fixed | §1.4.2 / §1.4.2.2 | P0-008 | 2026-01-21 | [L745](specs/CONTRACT.md#L745), [AT-934](specs/CONTRACT.md#L776), [L831](specs/CONTRACT.md#L831), [AT-929](specs/CONTRACT.md#L848) |
| AR5-F-004 | P0 | Fixed | §1.2.1 | P0-009 | 2026-01-21 | [L425](specs/CONTRACT.md#L425), [AT-935](specs/CONTRACT.md#L555) |
| AR5-F-005 | P1 | Fixed | §1.2 / §1.3 / §3.1 / §2.2.6 | P0-009 | 2026-01-21 | [AT-936](specs/CONTRACT.md#L562), [L594](specs/CONTRACT.md#L594), [L2015](specs/CONTRACT.md#L2015), [AT-937](specs/CONTRACT.md#L2069), [AT-938](specs/CONTRACT.md#L2076), [L1715](specs/CONTRACT.md#L1715) |
| AR5-T-002 | P1 | Fixed | §2.2.4 | P1-009 | 2026-01-21 | [L1613](specs/CONTRACT.md#L1613), [AT-430](specs/CONTRACT.md#L1640) |

---

## Audit Log

| Flow | Status | Date | Evidence |
|------|--------|------|----------|
| ACF-003 | Clean | 2026-01-21 | [gpt/bundle_ACF-003.md](gpt/bundle_ACF-003.md) |

---

## Finding Details

### AR-D-002: EvidenceGuard wording implies direct TradingMode setting
- **Description**: EvidenceGuard says it "forces TradingMode::ReduceOnly" without clarifying PolicyGuard mediation.
- **Impact**: Ambiguous authority boundary for TradingMode computation.
- **Proposed Fix**: Change wording to "PolicyGuard computes TradingMode::ReduceOnly based on EvidenceGuard inputs."

### AR-F-007: Margin Headroom Gate lacks AT-format test in §1.4.3
- **Description**: Margin Headroom Gate has unnumbered Given/When/Then bullets instead of AT-### blocks.
- **Impact**: Acceptance criteria are harder to validate mechanically.
- **Proposed Fix**: Add AT-### blocks for `mm_util_reject_opens`, `mm_util_reduceonly`, and `mm_util_kill`.

### AR2-D-003: Numeric thresholds repeated across sections
- **Description**: Thresholds (e.g., `mm_util_*`) are duplicated in §1.4.3 and §2.2.3.
- **Impact**: Drift risk if values diverge across sections.
- **Proposed Fix**: Centralize thresholds in Appendix A and reference them from both sections.

### AR-U-003: `AtomicNakedEvent` schema missing
- **Description**: `AtomicNakedEvent` is referenced for telemetry, but schema/fields are not defined.
- **Impact**: Telemetry cannot be validated consistently; auditability weakens.
- **Proposed Fix**: Add a minimal schema or reference an existing definition.

### AR-O-002: Unnumbered acceptance tests reduce enforceability
- **Description**: Operator-critical invariants rely on unnumbered "Acceptance Test:" blocks.
- **Impact**: Reduced standardization and CI enforceability.
- **Proposed Fix**: Convert key unnumbered tests to AT-### format.

### USR-U-601: EvidenceGuard CANCEL framing conflicts with risk-increasing cancel definition
- **Description**: EvidenceGuard frames CANCEL as risk-reducing, while Reflexive Cortex defines risk-increasing cancel/replace.
- **Impact**: Implementations may allow risk-increasing cancels under EvidenceGuard.
- **Proposed Fix**: Clarify that CANCEL is allowed only when not risk-increasing per §2.2.5.

### USR-T-603: Test-name-only lists not converted to AT blocks
- **Description**: Contract still lists test names (e.g., `test_truth_capsule_written_before_dispatch_and_fk_linked()` ) without AT-format criteria.
- **Impact**: Contract-level acceptance criteria remain weakly defined.
- **Proposed Fix**: Convert remaining test-name lists into AT-### blocks (backlog).

### AR3-F-001: Bunker Mode cancel/replace not bound to risk-increasing rules
- **Description**: Bunker Mode tests allowed CLOSE/HEDGE/CANCEL without asserting §2.2.5 risk-increasing cancel restrictions.
- **Impact**: Exposure could increase while bunker mode is active.
- **Proposed Fix**: Bind bunker cancel/replace to §2.2.5 and add AT-401.

### AR3-F-002: Open-permission latch did not block risk-increasing cancel/replace
- **Description**: §2.2.5 lacked an explicit latch condition and no AT asserted reject behavior.
- **Impact**: Risk-increasing cancel/replace could slip during reconciliation while OPEN is blocked.
- **Proposed Fix**: Add latch condition to §2.2.5 and add AT-402.

### AR3-T-001: `/status.connectivity_degraded` missing reconcile reasons
- **Description**: `/status` definition omitted `RESTART_RECONCILE_REQUIRED` and `INVENTORY_MISMATCH_RECONCILE_REQUIRED`.
- **Impact**: Operator truthfulness gap (false negatives).
- **Proposed Fix**: Add missing reason codes and test with AT-403.

### G-901: Missing AT for `mm_util_last_update_ts_ms` presence/parseability
- **Description**: No acceptance test forced ReduceOnly when `mm_util_last_update_ts_ms` is missing/unparseable.
- **Impact**: PolicyGuard could return Active while margin freshness is unknowable.
- **Proposed Fix**: Add AT-349.

### G-902: Missing AT for `disk_used_last_update_ts_ms` presence/parseability
- **Description**: No acceptance test forced ReduceOnly when `disk_used_last_update_ts_ms` is missing/unparseable.
- **Impact**: PolicyGuard could return Active while disk telemetry is unknowable.
- **Proposed Fix**: Add AT-350.

### O-701: `mode_reasons` completeness not test-enforced
- **Description**: Tests covered tier purity and ordering only, not completeness.
- **Impact**: Operator-lie-by-omission risk.
- **Proposed Fix**: Add AT-351 with multiple active reasons in one tier.

### O-702: `/status.connectivity_degraded` iff not fully tested
- **Description**: Only positive-path tests existed; no bunker path or negative-path test.
- **Impact**: False positives or negatives in `/status`.
- **Proposed Fix**: Add AT-352 and AT-353.

### AR3-F-003: EvidenceGuard risk-increasing cancel/replace not test-enforced
- **Description**: EvidenceGuard requires rejecting risk-increasing cancel/replace when EvidenceChainState is not GREEN, but no AT asserted the rejection.
- **Impact**: Exposure can increase while EvidenceChainState is not GREEN.
- **Proposed Fix**: Add AT-404 in §2.2.2.

### AR3-T-002: `/status.status_schema_version` value not tested
- **Description**: `/status` defines `status_schema_version` with current version = 1, but tests only assert key presence.
- **Impact**: Operator tooling can mis-handle schema changes or mismatches.
- **Proposed Fix**: Add AT-405.

### AR3-T-003: `/status.policy_age_sec` value not tested
- **Description**: `policy_age_sec` is required and formula-defined, but `/status` tests did not assert the computed value.
- **Impact**: Staleness visibility can be incorrect without failing any contract tests.
- **Proposed Fix**: Add AT-406.

---

## Patch Log

| Patch ID | Date | Findings | Description |
|----------|------|----------|-------------|
| PATCH-001 | 2026-01-19 | C-001, C-002, C-003, C-004 | Add missing full parameter entries to Appendix A per SL-F1 |
| P1-EG-001 | 2026-01-19 | AR-D-002, USR-U-601 | Clarify EvidenceGuard authority and align cancel semantics with §2.2.5. |
| P1-THR-DRIFT-001 | 2026-01-19 | AR2-D-003 | Remove numeric defaults from §1.4.3/ATs to reduce drift risk. |
| P1-TEST-AT-001 | 2026-01-19 | USR-T-603 | Add AT-046 and clarify test-name lists vs contract ATs. |
| P2-ANE-001 | 2026-01-19 | AR-U-003 | Define AtomicNakedEvent schema and add AT-211. |
| P2-ATSTD-001 | 2026-01-19 | AR-O-002 | Convert Orphan Fill acceptance test to AT-210. |
| P1-STATUS-002 | 2026-01-19 | AR2-O-001 | Add `connectivity_degraded` to `/status` and add AT-212. |
| P0-001 | 2026-01-20 | AR2-C-004 | Align Margin Headroom Kill containment with §2.2.3 eligibility. |
| P1-001 | 2026-01-20 | AR2-T-001 | Add /status latch=true invariants (AT-342). |
| P1-002 | 2026-01-20 | AR2-T-002 | Add idempotency hash time-independence test (AT-343). |
| P1-003 | 2026-01-20 | AR2-U-003 | Specify LiquidityGate missing/stale L2 snapshot handling + default. |
| P2-001 | 2026-01-20 | AR2-D-004 | Parameterize Cortex cooldowns to use Appendix A values. |
| P2-002 | 2026-01-20 | AR2-U-002 | Define Bunker “3 consecutive windows” and add AT-345. |
| P2-003 | 2026-01-20 | AR2-C-005 | Add §0.0 Normative Scope and clarify Patch Summary scope line. |
| P2-004 | 2026-01-20 | AR2-D-005 | Replace disk watermark literals with parameters and update tests. |
| P0-002 | 2026-01-20 | AR2-T-003, AR2-T-004, AR2-T-005 | Add Kill hard-stop containment tests and missing session-termination flag test. |
| P0-003 | 2026-01-20 | AR2-T-006 | Add /status read-only enforcement test. |
| P0-003 | 2026-01-20 | G-901, G-902 | Add AT-349/AT-350 for missing/unparseable mm_util and disk freshness timestamps. |
| P1-004 | 2026-01-20 | AR3-F-001, AR3-F-002 | Bind risk-increasing cancel/replace to bunker/latch constraints and add AT-401/AT-402. |
| P1-005 | 2026-01-20 | AR3-T-001, O-701, O-702 | Expand `/status.connectivity_degraded` reasons and add AT-351/AT-352/AT-353/AT-403. |
| P1-006 | 2026-01-20 | AR3-F-003, AR3-T-002, AR3-T-003 | Add AT-404/AT-405/AT-406 for EvidenceGuard cancel risk and /status truthfulness. |
| P0-004 | 2026-01-21 | AR4-D-001, AR4-D-002, AR4-C-001, AR4-U-002, AR4-U-003, AR4-F-302 | Define effective cortex_override aggregation, remove ws_gap_flag, standardize rate-limit counters, define depth_topN, and clarify LiquidityGate missing-L2 behavior with new ATs. |
| P1-007 | 2026-01-21 | AR4-T-001, AR4-T-002 | Add AT-901 and AT-902/AT-903/AT-904 for verify harness and review loop artifacts. |
| P1-008 | 2026-01-21 | AR4-T-003 | Add AT-905 for repo layout/workspace membership mapping. |
| P0-005 | 2026-01-21 | AR4-C-002 | Replace EvidenceGuard queue depth constants with config keys, fix queue_clear_window_s, and add AT-422. |
| P0-006 | 2026-01-21 | USR-F-001 | Add WAL writer isolation, bounded queue fail-closed behavior, expose WAL queue metrics in /status, and add AT-906. |
| P0-007 | 2026-01-21 | AR5-C-001 | Add dispatch authorization hot-path rule and AT-931. |
| P0-008 | 2026-01-21 | AR5-F-001, AR5-F-002, AR5-F-003, AR5-T-001 | Add missing input fail-closed rules and RejectReasonCode tokens, pending exposure ATs, and idempotency dedupe ATs (AT-926/928/929/932/933/934). |
| P0-009 | 2026-01-21 | AR5-F-004, AR5-F-005 | Require group intent persistence before leg dispatch; add containment rescue fallback and emergency close price-source rules with AT-935/936/937/938. |
| P1-009 | 2026-01-21 | AR5-T-002 | Add startup latch initialization test AT-430. |
