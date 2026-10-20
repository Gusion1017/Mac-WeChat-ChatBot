#!/usr/bin/env python3
"""Mock OpenAI-compatible chat server for local development (stdlib only).

Endpoints:
  GET  /v1/models
  POST /v1/chat/completions   (supports stream=true SSE and non-stream JSON)

The reply is a short, natural Chinese sentence derived from the last user
message, plus a canned marker so tests can assert the round trip.

Usage:
  python3 devtools/mock_ai.py --port 8787
"""
from __future__ import annotations

import argparse
import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def reply_for(messages) -> str:
    last = ""
    for message in reversed(messages or []):
        if message.get("role") == "user":
            last = str(message.get("content", ""))
            break
    last = last.strip().replace("\n", " ")
    if not last:
        return "你好呀，我在的～"
    clipped = last[:28]
    return f"收到：{clipped}。这是本地 Mock 模型的回复，链路正常 ✅"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, status: int, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/v1/models", "/models"):
            self.send_json(200, {
                "object": "list",
                "data": [{"id": "mock-chat", "object": "model", "owned_by": "local"}],
            })
            return
        if path == "/health":
            self.send_json(200, {"status": "ok"})
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        path = urlparse(self.path).path
        if path not in ("/v1/chat/completions", "/chat/completions"):
            self.send_json(404, {"error": {"message": "not found"}})
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            body = json.loads(self.rfile.read(length).decode() or "{}")
        except json.JSONDecodeError:
            self.send_json(400, {"error": {"message": "invalid json"}})
            return
        text = reply_for(body.get("messages"))
        model = body.get("model") or "mock-chat"
        stream = bool(body.get("stream"))
        print(f"[mock-ai] {model} stream={stream} -> {text}", flush=True)

        if not stream:
            self.send_json(200, {
                "id": "chatcmpl-" + uuid.uuid4().hex[:12],
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 32, "completion_tokens": len(text), "total_tokens": 32 + len(text)},
            })
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        chunk_id = "chatcmpl-" + uuid.uuid4().hex[:12]
        created = int(time.time())

        def emit(delta: dict, finish=None):
            payload = {
                "id": chunk_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            self.wfile.write(f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush()

        try:
            emit({"role": "assistant"})
            for piece in _split_utf8(text, 3):
                emit({"content": piece})
                time.sleep(0.04)
            emit({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()


def _split_utf8(text: str, size: int):
    return [text[i:i + size] for i in range(0, len(text), size)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"[mock-ai] listening on http://127.0.0.1:{args.port}/v1", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mock-ai] bye", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
