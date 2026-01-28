# Skill: Interview (Spec Building)

Source: [Thariq @trq212](https://x.com/trq212/status/2005315275026260309) from Claude Code team

Purpose
- Build detailed specs through structured Q&A
- Capture requirements before implementation
- Create auditable, versioned context (not opaque memory)

When to use
- Starting a new feature or PRD item
- Requirements are vague or incomplete
- Complex tradeoffs need exploration
- Before adding to prd.json

Prompt Template
```
Read @SPEC.md (or describe the feature) and interview me in detail using
the AskUserQuestionTool about literally anything:
- Technical implementation
- Edge cases and error handling
- Contract alignment (which sections apply?)
- Tradeoffs and alternatives
- Acceptance criteria

Be very in-depth. Continue interviewing until complete, then write the
detailed spec to the file.
```

Workflow
1. Create minimal spec file: `specs/features/FEATURE_NAME.md`
2. Run interview prompt
3. Answer questions (expect 40-75 for complex features)
4. Claude writes detailed spec
5. Review and commit spec
6. New session implements from spec

Integration with Ralph
- Interview output becomes PRD item input
- Spec file becomes `contract_refs` evidence
- Detailed spec = better `scope.touch` / `scope.avoid` patterns

Output
- Detailed spec file in `specs/features/`
- Ready for PRD item creation
- Clear acceptance criteria for verification
