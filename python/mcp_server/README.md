# Ralph Contract MCP Server

MCP server that provides Claude Code with direct access to contract validation and lookup tools.

## Installation

```bash
cd python/mcp_server
pip install -r requirements.txt
```

## Register with Claude Code

```bash
claude mcp add ralph -- python python/mcp_server/server.py
```

After registering, restart Claude Code for the MCP server to be available.

## Available Tools

### Contract Lookup

| Tool | Description |
|------|-------------|
| `contract_lookup(section)` | Get CONTRACT.md section by number (e.g., "2.2", "7.0") |
| `contract_search(query)` | Search CONTRACT.md with regex support |
| `list_acceptance_tests(section?)` | List AT-### tests, optionally filtered by section |
| `get_reason_codes(type)` | List RejectReasonCode, ModeReasonCode, or LatchReasonCode |

### Validation

| Tool | Description |
|------|-------------|
| `check_contract_crossrefs(strict?, check_at?)` | Validate section and AT references |
| `check_arch_flows(strict?)` | Validate architecture flows against contract |
| `check_state_machines()` | Validate state machine definitions |
| `run_all_checks()` | Run all validation checks |

### PRD

| Tool | Description |
|------|-------------|
| `get_prd_tasks(status?)` | List PRD tasks, optionally filtered by status |
| `get_prd_task(task_id)` | Get full details of a specific task |

## Example Usage (from Claude Code)

Once registered, these tools are available automatically:

```
# Look up a contract section
contract_lookup("2.2.3")

# Search for a term
contract_search("fail-closed")

# Run validation
check_contract_crossrefs()

# List pending tasks
get_prd_tasks("pending")
```

## Testing Standalone

```bash
# Test the server starts correctly
python python/mcp_server/server.py

# The server reads from stdin and writes to stdout (MCP protocol)
# Ctrl+C to exit
```

## Adding New Tools

Add new tools by decorating async functions with `@app.tool()`:

```python
@app.tool()
async def my_new_tool(arg1: str, arg2: int = 10) -> str:
    """
    Description of what this tool does.

    Args:
        arg1: Description of arg1
        arg2: Description of arg2 (default: 10)

    Returns description of output.
    """
    # Implementation
    return "result"
```

The docstring becomes the tool's description in Claude Code.
