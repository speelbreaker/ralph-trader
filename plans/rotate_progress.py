#!/usr/bin/env python3
import argparse
from datetime import datetime
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--keep", type=int, default=200)     # keep last N lines
    ap.add_argument("--archive", required=True)          # archive file path
    ap.add_argument("--max-lines", type=int, default=500)
    args = ap.parse_args()

    p = Path(args.file)
    if not p.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("", encoding="utf-8")

    lines = p.read_text(encoding="utf-8", errors="replace").splitlines(True)
    if len(lines) <= args.max_lines:
        return

    keep = max(0, args.keep)
    head = lines[:-keep] if keep and len(lines) > keep else []
    tail = lines[-keep:] if keep else []

    arch = Path(args.archive)
    arch.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

    with arch.open("a", encoding="utf-8") as f:
        f.write(f"\n\n=== ARCHIVE {ts} (rotated {len(head)} lines) ===\n")
        f.writelines(head)

    p.write_text("".join(tail), encoding="utf-8")


if __name__ == "__main__":
    main()
