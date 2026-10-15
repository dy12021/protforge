#!/usr/bin/env python3
"""Scan DSH session logs for skill-catalog entries.

Sessions are zstd-compressed JSONL. If the running instance rendered a skill
catalog after the install, the protforge skills appear in that stored context;
if they do not, the catalog is either stale or never generated, and neither can
be called proof that discovery worked.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    import zstandard
except ImportError:
    print("zstandard not installed; cannot read session.v4.jsonl.zstd", file=sys.stderr)
    raise SystemExit(2)

SESSIONS = Path.home() / ".dsh-beta" / "sessions"
NEEDLE = "protforge"


def decompress(path: Path) -> str:
    data = zstandard.ZstdDecompressor().decompress(path.read_bytes(), max_output_size=64 << 20)
    return data.decode("utf-8", errors="replace")


def main() -> int:
    files = sorted(SESSIONS.rglob("session.v4.jsonl.zstd"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        print(f"no session files under {SESSIONS}")
        return 2

    found_any = False
    for path in files:
        text = decompress(path)
        if NEEDLE not in text:
            continue
        found_any = True
        print(f"HIT  {path.parent.name}  ({path.stat().st_mtime_ns // 10**9})")
        for line in text.splitlines():
            if NEEDLE not in line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            blob = json.dumps(event, ensure_ascii=False)
            for name in sorted({s for s in blob.split('"') if s.startswith("protforge-")}):
                print(f"       catalog entry: {name}")

    if not found_any:
        print(f"no '{NEEDLE}' in any of {len(files)} session file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
