# SKILL: /pr-review (General PR Review)

Purpose
- Comprehensive PR review covering correctness, conventions, performance, and testing
- Lighter-weight than `/contract-review` for non-safety-critical code
- Complements `/contract-review` (use both for `crates/` changes)

When to use
- Reviewing any PR before merge
- Python tools and scripts
- Documentation changes
- Infrastructure/CI changes
- Non-safety-critical Rust code

## Review Process

### 1. Get PR Context
```bash
# If no PR number given, list open PRs
gh pr list --state open

# Get PR details
gh pr view <number>

# Get the diff
gh pr diff <number>
```

### 2. Review Checklist
- [ ] Read `reviews/REVIEW_CHECKLIST.md` and follow it.
- [ ] Ensure your response includes a "Review Coverage" section that lists every modified/added file with a 1-line review note each.

#### Correctness
- [ ] Logic is sound and handles edge cases
- [ ] Error handling is appropriate
- [ ] No obvious bugs or regressions
- [ ] Matches PR description / issue requirements

#### Conventions
- [ ] Follows CLAUDE.md coding standards
- [ ] Consistent naming and style
- [ ] No unnecessary complexity
- [ ] Comments where needed (but not obvious code)

#### Performance
- [ ] No obvious performance issues
- [ ] Appropriate data structures
- [ ] No unnecessary allocations in hot paths
- [ ] Async/concurrency handled correctly

#### Testing
- [ ] Tests cover the changes
- [ ] Tests are meaningful (not just coverage padding)
- [ ] Edge cases tested
- [ ] For new features: happy path + error path

#### Security (lightweight)
- [ ] No hardcoded secrets
- [ ] Input validation where needed
- [ ] No SQL/command injection risks
- [ ] (For safety-critical code: use `/contract-review` instead)

#### Documentation
- [ ] PR description is clear
- [ ] Code is self-documenting or has comments
- [ ] README/docs updated if needed
- [ ] Breaking changes documented

### Review Coverage (Required)
- Use `reviews/REVIEW_CHECKLIST.md` to confirm evidence/compounding gates and required workflow checks are covered.

### 3. Scope Check
- [ ] Changes match PR title/description
- [ ] No unrelated changes bundled in
- [ ] Appropriate size (not too large to review)

## Output Format

```markdown
## PR Review: #<number> - <title>

### Review Coverage
- <path> — <what changed + risk>

### Summary
Brief description of what this PR does.

### Verdict: APPROVE | REQUEST_CHANGES | COMMENT

### Correctness
- [x] Logic sound
- [ ] Issue: <description>

### Conventions
- [x] Follows standards
- [ ] Suggestion: <improvement>

### Performance
- [x] No concerns

### Testing
- [x] Adequate coverage
- [ ] Missing: <what needs testing>

### Recommendations
1. <specific suggestion with file:line>
2. <specific suggestion with file:line>

### Blockers (if REQUEST_CHANGES)
- <must fix before merge>
```

## Quick Commands

```bash
# View PR
gh pr view <number>

# Get diff
gh pr diff <number>

# Check CI status
gh pr checks <number>

# View specific file in PR
gh pr diff <number> -- path/to/file.rs

# Add review comment
gh pr review <number> --comment --body "..."

# Approve
gh pr review <number> --approve

# Request changes
gh pr review <number> --request-changes --body "..."
```

## When to Escalate to /contract-review

Use `/contract-review` instead (or in addition) when PR touches:
- `crates/soldier_core/`
- `crates/soldier_infra/`
- `specs/CONTRACT.md`
- `specs/state_machines/`
- Any TradingMode, PolicyGuard, or dispatch logic

## When to Use /failure-mode-review

Use `/failure-mode-review` for adversarial analysis when PR touches:
- Caching or persistence logic (ask: "what if cache is stale?")
- Cross-script integrations with env vars (ask: "does consumer read this var name?")
- State machines or lifecycle management (ask: "what if source disappears?")
- External input handling (files, JSON, env vars) (ask: "what if malformed?")

This skill focuses on "how will this code fail" rather than "does this code look right."

## Review Depth by File Type

| File Type | Depth | Focus |
|-----------|-------|-------|
| `crates/soldier_*` | Deep + `/contract-review` | Safety, correctness |
| `python/` | Medium | Correctness, types |
| `scripts/` | Medium | Correctness, error handling |
| `plans/` | Light | Logic, no regressions |
| `specs/` | Deep | Accuracy, cross-refs |
| `docs/` | Light | Clarity, accuracy |
| `.github/` | Medium | CI correctness |
