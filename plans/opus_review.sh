#!/usr/bin/env bash
# Opus 4.6 Expert Review Gate for Ralph
# Combines Code Review Expert (technical) + Thinking Expert (architectural/strategic)

set -euo pipefail

STORY_ID="${1:-}"
STORY_DESC="${2:-}"
HEAD_BEFORE="${3:-}"
HEAD_AFTER="${4:-}"
ITER_DIR="${5:-.ralph/iter}"

if [[ -z "$STORY_ID" || -z "$HEAD_BEFORE" || -z "$HEAD_AFTER" ]]; then
  echo "Usage: opus_review.sh STORY_ID STORY_DESC HEAD_BEFORE HEAD_AFTER [ITER_DIR]" >&2
  exit 1
fi

REVIEW_DIR="${ITER_DIR}/opus_review"
mkdir -p "$REVIEW_DIR"

REVIEW_OUTPUT="${REVIEW_DIR}/review.txt"
REVIEW_JSON="${REVIEW_DIR}/review.json"

# Get changed files
CHANGED_FILES="$(git diff --name-only "$HEAD_BEFORE" "$HEAD_AFTER" | grep -v '^plans/' || true)"
if [[ -z "$CHANGED_FILES" ]]; then
  echo "No implementation files changed (only plans/), skipping Opus review."
  exit 0
fi

# Get diff context
git diff "$HEAD_BEFORE" "$HEAD_AFTER" > "${REVIEW_DIR}/changes.diff"

# Get CONTRACT.md references from story
CONTRACT_REFS="$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .contract_refs[]' plans/prd.json 2>/dev/null || echo "None")"
ENFORCING_ATS="$(jq -r --arg id "$STORY_ID" '.items[] | select(.id == $id) | .enforcing_contract_ats[]' plans/prd.json 2>/dev/null || echo "None")"

# Build review prompt
cat > "${REVIEW_DIR}/review_prompt.txt" <<EOF
You are conducting a comprehensive safety review of PRD story **${STORY_ID}** before it can be marked as passing.

## Story Details

**ID**: ${STORY_ID}
**Description**: ${STORY_DESC}
**Contract References**: ${CONTRACT_REFS}
**Enforcing Acceptance Tests**: ${ENFORCING_ATS}

## Your Role

You are a **dual-mode expert reviewer** combining:

### 1. Code Review Expert (Technical "What" & "How")
Focus on immediate code quality:
- **Correctness**: Does the code fulfill requirements? Edge cases, null checks, error handling?
- **Readability & Maintainability**: Meaningful names, clear logic, DRY principles?
- **Security & Compliance**: Hardcoded secrets, injection risks (SQL, XSS), unsafe data handling?
- **Performance**: Bottlenecks, unnecessary loops, inefficient algorithms, redundant calls?
- **Styling & Best Practices**: Language-specific standards (rustfmt, clippy warnings)?

### 2. Thinking Expert (Architectural/Strategic "Why" & "Context")
Focus on broader implications:
- **Contextual Awareness**: Broader purpose within the system?
- **Architectural Alignment**: Design patterns, modularity, long-term scalability?
- **Logic & Causality**: Mental simulation - do inputs transform correctly to outputs? Logical flaws?
- **Technical Debt Management**: Works now but hard to maintain later?
- **Critique of Assumptions**: Question underlying assumptions to find hidden flaws?

## Changed Files

$(echo "$CHANGED_FILES" | sed 's/^/- /')

## Review Checklist

For each changed file, analyze:

### Code Review Expert Checks
- [ ] Edge cases handled (empty inputs, boundary conditions, overflow)
- [ ] Error handling complete (Result types unwrapped safely, panics avoided)
- [ ] No hardcoded secrets or credentials
- [ ] No SQL injection, XSS, or command injection risks
- [ ] Thread safety (Mutex used correctly, no race conditions, no deadlocks)
- [ ] Memory safety (no leaks, proper Drop implementation if needed)
- [ ] Performance acceptable (no N^2 algorithms, efficient data structures)
- [ ] Naming clear and consistent with codebase conventions
- [ ] No code duplication that should be abstracted

### Thinking Expert Checks
- [ ] Aligns with CONTRACT.md requirements and acceptance tests
- [ ] Follows established architectural patterns (fail-closed, no unwrap in prod, etc.)
- [ ] State machine transitions are correct and complete
- [ ] Assumptions are valid and documented
- [ ] Future maintainability - will this be hard to change later?
- [ ] Integration points - does this compose well with existing code?
- [ ] Observable - sufficient logging/metrics for production debugging?
- [ ] Testable - unit tests cover the right scenarios?

## Contract Alignment

Read the CONTRACT.md sections: ${CONTRACT_REFS}

Verify:
1. All CONTRACT.md requirements are implemented
2. Acceptance tests (${ENFORCING_ATS}) are addressed
3. No shortcuts or assumptions that violate the contract
4. Fail-closed behavior where required

## Changes Diff

\`\`\`diff
$(cat "${REVIEW_DIR}/changes.diff")
\`\`\`

## Your Review

Provide a structured review in this format:

### Code Review Expert Findings

**Correctness**:
- [List any correctness issues or ✓ if none]

**Readability & Maintainability**:
- [List any readability issues or ✓ if none]

**Security & Compliance**:
- [List any security issues or ✓ if none]

**Performance**:
- [List any performance issues or ✓ if none]

**Styling & Best Practices**:
- [List any style issues or ✓ if none]

### Thinking Expert Findings

**Contextual Awareness**:
- [Does this fit the broader system? Any misalignment?]

**Architectural Alignment**:
- [Does this follow established patterns? Any technical debt concerns?]

**Logic & Causality**:
- [Mental simulation results - any logical flaws?]

**Critique of Assumptions**:
- [Any questionable assumptions? Hidden edge cases?]

### Contract Compliance

- [Verify each CONTRACT.md requirement is met]
- [Verify each acceptance test is addressed]

### Decision

**APPROVE** or **REJECT**

If REJECT, provide:
1. Severity: CRITICAL | HIGH | MEDIUM | LOW
2. Blocking issues that must be fixed before approval
3. Suggested fixes

---

Begin your review:
EOF

echo "=== Launching Opus 4.6 Review for ${STORY_ID} ===" | tee "$REVIEW_OUTPUT"
echo "" | tee -a "$REVIEW_OUTPUT"

# Launch Claude with Opus model
if ! claude --model opus < "${REVIEW_DIR}/review_prompt.txt" >> "$REVIEW_OUTPUT" 2>&1; then
  echo "ERROR: Opus review execution failed" >&2
  exit 2
fi

# Parse review decision
DECISION="$(grep -E "^\*\*APPROVE\*\*|^\*\*REJECT\*\*|^APPROVE$|^REJECT$" "$REVIEW_OUTPUT" | head -1 | tr -d '*' || echo "UNKNOWN")"

# Create JSON summary
cat > "$REVIEW_JSON" <<JSON
{
  "story_id": "$STORY_ID",
  "decision": "$DECISION",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "changed_files": $(echo "$CHANGED_FILES" | jq -R -s 'split("\n") | map(select(length > 0))'),
  "review_output_path": "$REVIEW_OUTPUT"
}
JSON

echo "" | tee -a "$REVIEW_OUTPUT"
echo "=== Review Decision: $DECISION ===" | tee -a "$REVIEW_OUTPUT"

if [[ "$DECISION" == "APPROVE" ]]; then
  echo "✓ Opus review APPROVED story ${STORY_ID}" | tee -a "$REVIEW_OUTPUT"
  exit 0
elif [[ "$DECISION" == "REJECT" ]]; then
  echo "✗ Opus review REJECTED story ${STORY_ID}" | tee -a "$REVIEW_OUTPUT"
  echo "See detailed findings in: $REVIEW_OUTPUT" | tee -a "$REVIEW_OUTPUT"
  exit 1
else
  echo "ERROR: Could not parse Opus review decision (got: $DECISION)" >&2
  echo "Review output saved to: $REVIEW_OUTPUT" >&2
  exit 2
fi
