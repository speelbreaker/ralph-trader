# Skill: Patch-Only Edits

Purpose
- Make minimal, targeted changes without broad refactors.

When to use
- Contract/harness changes with strict scope controls.
- PRD patching tasks.

Checklist
- Locate the smallest viable change location.
- Use apply_patch for single-file changes when possible.
- Avoid reformatting or unrelated whitespace changes.
- Keep changes atomic and reversible.

Output
- Focused diff with only intended lines changed.
