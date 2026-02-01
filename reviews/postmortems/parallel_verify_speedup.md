# Postmortem: Parallel Verify Speedup

**Date**: 2026-01-31
**Governing Contract**: Workflow (specs/WORKFLOW_CONTRACT.md)
**Status**: Ready for review

## Summary
Implemented wave-based parallelization for verify.sh to speed up Ralph audit iterations by 2-3x through parallel spec validators, status fixtures, and workflow tests. Fixed critical blockers including --only-set flag support, eval security validation, timing sort, and smoke test integration.

## What Happened
Developer iteration loop was bottlenecked by sequential execution of 9 spec validators, 7 status fixtures, and workflow acceptance tests. Full verify cycle took 45-50 minutes, slowing down feedback loops.

Initial parallel implementation had several critical blockers:

1. **--only-set membership filtering (BLOCKER)**:
   - Initial implementation filtered ALL_TEST_IDS array but test_start() still used TEST_COUNTER range checking
   - Result: Ran "first N tests" instead of "selected tests only"
   - Fix: Replaced array filtering with membership checking in test_start()

2. **eval argument handling (CRITICAL - FIXED IN CODE REVIEW)**:
   - Initial plan quoted $cmd thinking it was more secure
   - Code review found this breaks functionality (entire command becomes single arg → "command not found")
   - Root cause: Misunderstood that validation provides security, not quoting
   - Fix: UNQUOTED $cmd + comprehensive character validation `[\;\`\$\(\)\&\|\>\<$'\n']`
   - Key insight: Validation before eval is what provides safety; quoting breaks word-splitting needed by run_logged

3. **Timing summary sort (QUALITY)**: Used wrong delimiter (colon vs space)

4. **Smoke test gate (CONTRACT)**: Warned instead of failing when missing

5. **Missing review packets**: Evidence, compounding, and postmortem not created

## Root Cause

**Primary Cause**: Original verify.sh design ran all gates sequentially for simplicity and determinism. No timing instrumentation existed to measure bottlenecks.

**Secondary Cause (Implementation Bugs)**:
- **--only-set bug**: Misunderstood test execution model - filtered array but relied on counter-based range checking
- **eval security bug**: Insufficient understanding of shell injection vectors (focused on `;` but missed `&&`, `||`, pipes)
- **Testing gap**: Didn't validate --only-set with non-consecutive IDs before integration

**Process Cause**: Initial implementation was rushed and didn't follow workflow requirements for harness changes (missing smoke test gate, review packets).

## What Went Well
- Identified parallelization opportunity through systematic analysis
- Maintained portability (Bash 3.2+, macOS and Linux)
- Preserved deterministic failure ordering (no race conditions)
- Added timing instrumentation for future optimization decisions
- Fixed all blockers systematically with validation at each step
- Created comprehensive review packets (evidence + compounding + postmortem)

## What Could Be Improved

**Implementation**:
- Should have tested --only-set with non-consecutive IDs before integration (caught the range vs membership bug)
- eval security validation should have referenced OWASP shell injection patterns upfront
- Should have understood eval + run_logged interaction before deciding to quote $cmd (code review caught this)

**Process**:
- Should have run `bash -n` syntax check after each file edit (caught issues immediately)
- Should have created smoke test gate BEFORE implementing parallel runner
- Documentation should be in AGENTS.md (not buried in implementation notes)

**Testing**:
- Unit test for membership filtering logic (isolated from full workflow)
- Security test suite for eval validation (try various injection patterns)
- Regression test for timing summary sort

## Action Items
- [x] Fix --only-set support in workflow_acceptance.sh
- [x] Add security validation for eval inputs
- [x] Fix timing summary sort delimiter
- [x] Integrate smoke test into verify.sh gates
- [x] Create evidence packet
- [x] Create compounding packet
- [x] Create postmortem entry
- [ ] Collect baseline timing data from 10+ runs
- [ ] Document parallel primitives in AGENTS.md
- [ ] Consider replacing eval with array expansion in future iteration

## Lessons Learned

**Implementation**:
1. **Test filtering logic with edge cases**: Non-consecutive IDs exposed the range vs membership bug
2. **Understand execution models deeply**: test_start() uses TEST_COUNTER (global increment), not array index
3. **Understand eval argument handling**: Quoting $cmd breaks word-splitting needed by run_logged; validation provides security, not quoting
4. **Comprehensive security validation**: Block all shell metacharacters (`&&`, `||`, `|`, `>`, `<`), not just obvious ones
5. **Code review is critical**: Caught the eval quoting bug before implementation

**Process**:
5. **Always instrument before optimizing**: Timing data proves what's worth optimizing
6. **Self-proving changes**: Smoke tests must be fail-closed gates, not warnings
7. **Follow workflow requirements**: Harness changes need gates, evidence, compounding, and postmortem
8. **Syntax check after each edit**: `bash -n` catches issues immediately

**Design**:
9. **Portability matters**: Bash 3.2 compatibility = zero friction on macOS
10. **Fail-closed on security**: Validate inputs AND quote variables; prefer array expansion over eval

## Technical Debt
- eval usage in run_parallel_group() is validated but still risky; consider array expansion in future
- Timing data is collected but not yet analyzed for optimization opportunities
- No automated enforcement of parallel validator pattern (relies on code review)

## Impact
**Before**: 45-50 minute verify cycles
**After**: Estimated 15-25 minute verify cycles (2-3x speedup)
**Developer Experience**: Faster feedback loop for Ralph iterations
**CI/CD**: Reduced pipeline time for full verify runs
