#!/usr/bin/env python3
"""Minimal local OpenTelemetry receiver for Claude Code's usage events.

Claude Code pushes its telemetry itself (nothing here polls anything): with
the env vars install.sh merges into ~/.claude/settings.json, every Claude
process - interactive or `claude -p` - POSTs batches of OTLP log records as
JSON to http://127.0.0.1:4318/v1/logs every few seconds. This server accepts
those batches and appends one row per usage event to
data/claude-telemetry.jsonl. See USAGE_DATA_SOURCES.md §3.7 for what the
events carry and why: they are the only per-request record that includes
the requests Claude Code never writes to its transcripts.

Only usage events are kept (USAGE_EVENTS); prompt, tool and hook events are
dropped on arrival. Each kept record is flattened losslessly: OTLP's typed
{key, value: {stringValue|intValue|...}} attribute lists become plain JSON
objects, and intValue (a string in OTLP/JSON) becomes an int.

Stdlib only, bound to 127.0.0.1, run by its own KeepAlive LaunchAgent. If it
is down, Claude Code drops the batches - it does not buffer them on disk.

Usage: python3 otlp_receiver.py [--port 4318] [--out <jsonl path>]
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Deployed at ~/opt/agent-statusline/src/telemetry/ - three parents up is the
# runtime root holding data/ (same layout as src/quota_polling/).
RUNTIME_DIR = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUT = RUNTIME_DIR / "data" / "claude-telemetry.jsonl"
USAGE_EVENTS = {"api_request", "api_error", "api_refusal", "api_retries_exhausted"}
MAX_BODY_BYTES = 16 * 1024 * 1024


def flatten_value(d_value: dict):
    """One OTLP AnyValue -> plain JSON value."""
    if "stringValue" in d_value:
        return d_value["stringValue"]
    if "intValue" in d_value:
        return int(d_value["intValue"])
    if "doubleValue" in d_value:
        return d_value["doubleValue"]
    if "boolValue" in d_value:
        return d_value["boolValue"]
    if "arrayValue" in d_value:
        return [flatten_value(v) for v in d_value["arrayValue"].get("values", [])]
    if "kvlistValue" in d_value:
        return flatten_attrs(d_value["kvlistValue"].get("values", []))
    return None  # empty AnyValue


def flatten_attrs(l_attrs: list) -> dict:
    return {d["key"]: flatten_value(d.get("value", {})) for d in l_attrs}


def usage_rows(d_payload: dict, received_at: int) -> list[dict]:
    """ExportLogsServiceRequest -> one row per usage event record."""
    l_rows = []
    for d_rl in d_payload.get("resourceLogs", []):
        d_resource = flatten_attrs(d_rl.get("resource", {}).get("attributes", []))
        for d_sl in d_rl.get("scopeLogs", []):
            for d_rec in d_sl.get("logRecords", []):
                d_attrs = flatten_attrs(d_rec.get("attributes", []))
                # event.name is the bare name ("api_request"); the body holds
                # the prefixed one ("claude_code.api_request") - accept either.
                event = d_attrs.get("event.name") or str(flatten_value(d_rec.get("body", {})) or "")
                event = event.removeprefix("claude_code.")
                if event not in USAGE_EVENTS:
                    continue
                l_rows.append({
                    "received_at": received_at,
                    "event": event,
                    "time_unix_nano": int(d_rec.get("timeUnixNano") or 0),
                    "attributes": d_attrs,
                    "resource": d_resource,
                })
    return l_rows


def make_handler(out_path: Path, lock: threading.Lock):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, code: int, body: bytes = b"{}"):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY_BYTES:
                return self._reply(413)
            raw = self.rfile.read(length)
            # Metrics and traces aren't enabled by install.sh; accept and
            # discard them anyway so a misconfigured exporter doesn't retry.
            if self.path != "/v1/logs":
                return self._reply(200)
            if "json" not in (self.headers.get("Content-Type") or ""):
                return self._reply(415, b'{"error":"send OTLP as http/json"}')
            try:
                l_rows = usage_rows(json.loads(raw), int(time.time()))
            except (ValueError, TypeError, AttributeError) as exc:
                print(f"bad payload: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
                return self._reply(400)
            if l_rows:
                data = "".join(json.dumps(d) + "\n" for d in l_rows)
                with lock:
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                    with out_path.open("a") as f:
                        f.write(data)
            self._reply(200)

        def log_message(self, *args):
            pass  # no per-request access log; errors still go to stderr

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4318)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args.out, threading.Lock()))
    print(f"listening on 127.0.0.1:{args.port}, writing {args.out}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
