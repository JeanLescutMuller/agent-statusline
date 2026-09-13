"""Shared helpers for poll_claude.py and poll_codex.py: tail-reading a
growing JSONL quota log, and checking a heartbeat file's freshness. Not a
standalone entry point - both pollers stay independently runnable (see
poll_all.py's docstring for why each is still spawned as its own
subprocess), they just import this module from their own directory, same as
any other local import for a script run directly with `python3 poll_x.py`.
"""
import json
from pathlib import Path

CHUNK_BYTES = 16384


def tail_json_rows(log_file: Path) -> list[dict]:
    """Parsed rows from the tail of a JSONL log, newest last. Reads at most
    CHUNK_BYTES from the end - this runs every tick, forever, and the log
    only grows - and skips any line that fails to parse (at worst the first
    line of a non-full-file chunk, if the read boundary split a record)
    rather than raising."""
    if not log_file.exists():
        return []
    with log_file.open("rb") as f:
        f.seek(0, 2)
        size = f.tell()
        chunk = min(size, CHUNK_BYTES)
        f.seek(size - chunk)
        data = f.read(chunk)
    rows = []
    for line in data.splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def is_fresh(path: Path, window_seconds: float, now: float) -> bool:
    """True if `path`'s mtime is within window_seconds of now - the shared
    shape behind both pollers' heartbeat-driven speedup. A missing file just
    means False, which degrades gracefully to whichever idle cadence the
    caller falls back to."""
    try:
        return (now - path.stat().st_mtime) < window_seconds
    except OSError:
        return False
