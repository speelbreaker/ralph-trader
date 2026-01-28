#!/usr/bin/env python3
"""
Ralph Contract MCP Server

Provides Claude Code with direct access to contract validation,
section lookup, and verification tools.

Usage:
    # Register with Claude Code:
    claude mcp add ralph -- python python/mcp_server/server.py

    # Or run standalone for testing:
    python python/mcp_server/server.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    print(
        "ERROR: MCP package not installed. Run: pip install mcp",
        file=sys.stderr,
    )
    sys.exit(1)

# Project root (relative to this file)
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CONTRACT_PATH = PROJECT_ROOT / "specs" / "CONTRACT.md"
FLOWS_PATH = PROJECT_ROOT / "specs" / "flows" / "ARCH_FLOWS.yaml"
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
PLANS_DIR = PROJECT_ROOT / "plans"
PRD_PATH = PLANS_DIR / "prd.json"

# Create the MCP server
mcp = FastMCP("ralph")


# -----------------------------------------------------------------------------
# Contract Lookup Tools
# -----------------------------------------------------------------------------


@mcp.tool()
def contract_lookup(section: str) -> str:
    """
    Look up a CONTRACT.md section by number (e.g., '2.2', '2.2.3', '7.0').

    Returns the section heading and content up to the next section of equal
    or higher level.
    """
    if not CONTRACT_PATH.exists():
        return f"ERROR: CONTRACT.md not found at {CONTRACT_PATH}"

    text = CONTRACT_PATH.read_text(encoding="utf-8")
    lines = text.splitlines()

    # Pattern to match section headings like "## 2.2 PolicyGuard" or "### 2.2.3 Axis Resolver"
    heading_re = re.compile(
        r"^(#{1,6})\s+\*?\*?(" + re.escape(section) + r"(?:\.\d+)*)\b"
    )

    start_idx = None
    start_level = 0

    for i, line in enumerate(lines):
        m = heading_re.match(line)
        if m and m.group(2) == section:
            start_idx = i
            start_level = len(m.group(1))
            break

    if start_idx is None:
        return f"Section '{section}' not found in CONTRACT.md"

    # Find the end: next heading of same or higher level
    end_idx = len(lines)
    for i in range(start_idx + 1, len(lines)):
        line = lines[i]
        if line.startswith("#"):
            level = len(line) - len(line.lstrip("#"))
            if level <= start_level:
                end_idx = i
                break

    content = "\n".join(lines[start_idx:end_idx])

    # Truncate if too long
    if len(content) > 8000:
        content = content[:8000] + "\n\n... [truncated, section too long]"

    return content


@mcp.tool()
def contract_search(query: str, context_lines: int = 2) -> str:
    """
    Search CONTRACT.md for a term or pattern.

    Args:
        query: Search term or regex pattern
        context_lines: Number of context lines before/after match (default: 2)

    Returns matching lines with context and line numbers.
    """
    if not CONTRACT_PATH.exists():
        return f"ERROR: CONTRACT.md not found at {CONTRACT_PATH}"

    text = CONTRACT_PATH.read_text(encoding="utf-8")
    lines = text.splitlines()

    try:
        pattern = re.compile(query, re.IGNORECASE)
    except re.error as e:
        return f"Invalid regex pattern: {e}"

    matches = []
    for i, line in enumerate(lines):
        if pattern.search(line):
            start = max(0, i - context_lines)
            end = min(len(lines), i + context_lines + 1)
            snippet = []
            for j in range(start, end):
                prefix = ">>> " if j == i else "    "
                snippet.append(f"{prefix}L{j + 1}: {lines[j]}")
            matches.append("\n".join(snippet))

    if not matches:
        return f"No matches found for '{query}'"

    # Limit output
    if len(matches) > 20:
        matches = matches[:20]
        matches.append("\n... and more matches (showing first 20)")

    return "\n\n---\n\n".join(matches)


@mcp.tool()
def list_acceptance_tests(section: str | None = None) -> str:
    """
    List acceptance tests (AT-###) from CONTRACT.md.

    Args:
        section: Optional section filter (e.g., '2.2' to list ATs in that section)

    Returns list of AT IDs with their descriptions.
    """
    if not CONTRACT_PATH.exists():
        return f"ERROR: CONTRACT.md not found at {CONTRACT_PATH}"

    text = CONTRACT_PATH.read_text(encoding="utf-8")

    # Find all AT-### references with context
    at_pattern = re.compile(r"^\s*(AT-\d+)[:\s]+(.*)$", re.MULTILINE)
    matches = at_pattern.findall(text)

    if not matches:
        return "No acceptance tests found"

    result = []
    for at_id, description in matches:
        desc = description.strip()[:100]  # Truncate long descriptions
        result.append(f"{at_id}: {desc}")

    return "\n".join(sorted(set(result), key=lambda x: int(x.split("-")[1].split(":")[0])))


# -----------------------------------------------------------------------------
# Validation Tools (wrap existing scripts)
# -----------------------------------------------------------------------------


def _run_script(script_path: Path, *args: str, timeout: int = 60) -> tuple[int, str, str]:
    """Run a Python script and capture output."""
    cmd = [sys.executable, str(script_path)] + list(args)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=PROJECT_ROOT,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"Script timed out after {timeout}s"
    except Exception as e:
        return -1, "", str(e)


@mcp.tool()
def check_contract_crossrefs(strict: bool = True, check_at: bool = True) -> str:
    """
    Run the contract cross-reference checker.

    Validates:
    - Section references (e.g., see section 2.2) resolve
    - AT-### references resolve to defined tests
    - Heading IDs are unique

    Args:
        strict: Treat warnings as errors
        check_at: Also check AT-### references

    Returns validation results.
    """
    script = SCRIPTS_DIR / "check_contract_crossrefs.py"
    if not script.exists():
        return f"ERROR: Script not found at {script}"

    args = ["--contract", str(CONTRACT_PATH)]
    if strict:
        args.append("--strict")
    if check_at:
        args.append("--check-at")

    code, stdout, stderr = _run_script(script, *args)

    output = stdout + stderr
    status = "PASS" if code == 0 else "FAIL"

    return f"Status: {status} (exit code {code})\n\n{output}"


@mcp.tool()
def check_arch_flows(strict: bool = True) -> str:
    """
    Run the architecture flows checker.

    Validates:
    - Flow refs (AT-###, section refs) exist in CONTRACT.md
    - Flow 'where' paths exist
    - Every CONTRACT 'Where:' is covered by a flow

    Returns validation results.
    """
    script = SCRIPTS_DIR / "check_arch_flows.py"
    if not script.exists():
        return f"ERROR: Script not found at {script}"

    args = [
        "--contract", str(CONTRACT_PATH),
        "--flows", str(FLOWS_PATH),
    ]
    if strict:
        args.append("--strict")

    code, stdout, stderr = _run_script(script, *args)

    output = stdout + stderr
    status = "PASS" if code == 0 else "FAIL"

    return f"Status: {status} (exit code {code})\n\n{output}"


@mcp.tool()
def check_state_machines() -> str:
    """
    Run the state machine checker.

    Validates state machine definitions in specs/state_machines/.
    """
    script = SCRIPTS_DIR / "check_state_machines.py"
    if not script.exists():
        return f"ERROR: Script not found at {script}"

    code, stdout, stderr = _run_script(script)

    output = stdout + stderr
    status = "PASS" if code == 0 else "FAIL"

    return f"Status: {status} (exit code {code})\n\n{output}"


@mcp.tool()
def run_all_checks() -> str:
    """
    Run all contract validation checks.

    Equivalent to running verify.sh for contract integrity.
    Returns summary of all check results.
    """
    results = []

    # Cross-refs
    results.append("=== Contract Cross-References ===")
    results.append(check_contract_crossrefs())
    results.append("")

    # Arch flows
    results.append("=== Architecture Flows ===")
    results.append(check_arch_flows())
    results.append("")

    # State machines (if script exists)
    script = SCRIPTS_DIR / "check_state_machines.py"
    if script.exists():
        results.append("=== State Machines ===")
        results.append(check_state_machines())

    return "\n".join(results)


# -----------------------------------------------------------------------------
# PRD Tools
# -----------------------------------------------------------------------------


@mcp.tool()
def get_prd_tasks(status: str | None = None) -> str:
    """
    Get tasks from prd.json.

    Args:
        status: Optional filter by status ('pending', 'in_progress', 'done')

    Returns list of PRD tasks.
    """
    if not PRD_PATH.exists():
        return f"ERROR: prd.json not found at {PRD_PATH}"

    try:
        data = json.loads(PRD_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        return f"ERROR: Invalid JSON in prd.json: {e}"

    tasks = data.get("tasks", [])

    if status:
        tasks = [t for t in tasks if t.get("status") == status]

    if not tasks:
        return f"No tasks found" + (f" with status '{status}'" if status else "")

    result = []
    for t in tasks:
        tid = t.get("id", "?")
        title = t.get("title", "Untitled")
        st = t.get("status", "unknown")
        result.append(f"[{tid}] ({st}) {title}")

    return "\n".join(result)


@mcp.tool()
def get_prd_task(task_id: str) -> str:
    """
    Get full details of a specific PRD task.

    Args:
        task_id: The task ID (e.g., 'T-001')

    Returns full task details as JSON.
    """
    if not PRD_PATH.exists():
        return f"ERROR: prd.json not found at {PRD_PATH}"

    try:
        data = json.loads(PRD_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        return f"ERROR: Invalid JSON in prd.json: {e}"

    tasks = data.get("tasks", [])
    task = next((t for t in tasks if t.get("id") == task_id), None)

    if not task:
        return f"Task '{task_id}' not found"

    return json.dumps(task, indent=2)


# -----------------------------------------------------------------------------
# Utility Tools
# -----------------------------------------------------------------------------


@mcp.tool()
def get_reason_codes(code_type: str = "all") -> str:
    """
    List reason codes from CONTRACT.md.

    Args:
        code_type: 'reject' for RejectReasonCode, 'mode' for ModeReasonCode,
                   'latch' for LatchReasonCode, or 'all'

    Returns list of reason codes with descriptions.
    """
    if not CONTRACT_PATH.exists():
        return f"ERROR: CONTRACT.md not found at {CONTRACT_PATH}"

    text = CONTRACT_PATH.read_text(encoding="utf-8")

    patterns = {
        "reject": r"`(Reject\w+)`",
        "mode": r"`(Mode\w+)`",
        "latch": r"`(Latch\w+)`",
    }

    if code_type == "all":
        pattern = r"`((?:Reject|Mode|Latch)\w+)`"
    elif code_type in patterns:
        pattern = patterns[code_type]
    else:
        return f"Unknown code_type '{code_type}'. Use 'reject', 'mode', 'latch', or 'all'"

    codes = sorted(set(re.findall(pattern, text)))

    if not codes:
        return f"No {code_type} codes found"

    return "\n".join(codes)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


if __name__ == "__main__":
    mcp.run()
