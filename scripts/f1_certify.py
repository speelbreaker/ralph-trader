#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "python" / "tools" / "f1_certify.py"


def main() -> int:
    if not TOOL.is_file():
        print(f"ERROR: missing tool: {TOOL}", file=sys.stderr)
        return 1
    result = subprocess.run([sys.executable, str(TOOL), *sys.argv[1:]])
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
