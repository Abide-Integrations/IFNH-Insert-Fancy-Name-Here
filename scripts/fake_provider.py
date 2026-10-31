#!/usr/bin/env python3
"""Bench-only fake OpenAI-compatible SSE server (scripts/bench.sh). Not shipped."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def chunk(choices, **extra):
    return "data: " + json.dumps({"id": "bench", "choices": choices, **extra}) + "\n\n"


USAGE = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
TEXT_REPLY = "bench"
TOOL_FILE = ".ifnh/ask-smoke.txt"
DONE = "x"


def text_stream(text):
    return (
        chunk([{"index": 0, "delta": {"role": "assistant", "content": text}}])
        + chunk([{"index": 0, "delta": {}, "finish_reason": "stop"}])
        + chunk([], usage=USAGE)
        + DONE
    )


# Scripted first-round tool calls per mode. `bash touch` is state-changing, so
# the permission engine asks; it really runs in the workspace. `write`/`edit`
# exercise the approval diff preview and project grants (C-05).
TOOL_CALLS = {
    "tool": ("bash", {"command": "touch " + TOOL_FILE}),
    "write": ("write", {"path": "smoke.txt", "content": "alpha\nbeta\ngamma\n"}),
    "edit": ("edit", {"path": "smoke.txt", "old_string": "beta", "new_string": "BETA"}),
}


def tool_stream(mode):
    name, call_args = TOOL_CALLS[mode]
    args = json.dumps(call_args)
    return (
        chunk([{"index": 0, "delta": {"role": "assistant", "content": ""}}])
        + chunk([{"index": 0, "delta": {"tool_calls": [{
            "index": 0,
            "id": "call_fake_1",
            "type": "function",
            "function": {"name": name, "arguments": args},
        }]}}])
        + chunk([{"index": 0, "delta": {}, "finish_reason": "tool_calls"}])
        + chunk([], usage=USAGE)
        + DONE
    )


def has_tool_result(raw):
    """True when the request already carries a tool result (round 2+)."""
    try:
        request = json.loads(raw or b"{}")
    except (TypeError, ValueError):
        return False
    return any(m.get("role") == "tool" for m in request.get("messages", []))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # close-delimited body

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return
        time.sleep(self.server.delay)
        # --mode error: a hard provider failure (HTTP 500).
        if self.server.mode == "error":
            body = json.dumps({"error": {"message": "fake provider: boom"}}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        body = text_stream(TEXT_REPLY)
        if self.server.mode in TOOL_CALLS and not has_tool_result(raw):
            body = tool_stream(self.server.mode)
        self.wfile.write(body.encode())

    def log_message(self, *args):

        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file")
    ap.add_argument("--mode", choices=("text", "error") + tuple(TOOL_CALLS), default="text")
    ap.add_argument("--delay", type=float, default=0.03)
    a = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", a.port), Handler)
    srv.delay = a.delay
    srv.mode = a.mode
    if a.port_file:
        with open(a.port_file, "w") as f:
            f.write("127.0.0.1:%d\n" % srv.server_address[1])
    srv.serve_forever()


if __name__ == "__main__":
    main()
