#!/usr/bin/env python3
"""Mock OneBot 11 gateway for local development (stdlib only).

Emulates the exact HTTP/WS contract used by bridge/onebot:

  GET  /ws                      WebSocket push channel
  POST /send_private_msg        Bearer token + JSON body
  POST /send_group_msg          Bearer token + JSON body
  POST /inject                  push an arbitrary event JSON to all WS clients
  POST /demo                    start the built-in demo script
  GET  /health                  status JSON

Sent messages are appended to --sent-log (JSONL) for assertions.

Usage:
  python3 devtools/mock_onebot.py --port 58080 --token wechatai-local-token --demo
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import struct
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

SELF_ID = "wxid_self"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

STATE = {
    "clients": set(),
    "lock": threading.Lock(),
    "sent": [],
    "received_actions": 0,
}
CONFIG = {"token": "wechatai-local-token", "sent_log": "/tmp/wechatai-mock-sent.jsonl", "self_id": SELF_ID}


def now() -> int:
    return int(time.time())


def log_sent(entry: dict) -> None:
    STATE["sent"].append(entry)
    try:
        with open(CONFIG["sent_log"], "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def ws_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    header = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    return bytes(header) + payload


def ws_send(conn, obj) -> bool:
    try:
        conn.sendall(ws_frame(json.dumps(obj, ensure_ascii=False).encode()))
        return True
    except OSError:
        return False


def broadcast(obj) -> int:
    with STATE["lock"]:
        clients = list(STATE["clients"])
    ok = 0
    for conn in clients:
        if ws_send(conn, obj):
            ok += 1
    return ok


def recv_exact(conn, n: int):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def ws_recv(conn):
    hdr = recv_exact(conn, 2)
    if not hdr:
        return None
    b1, b2 = hdr
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(conn, 8))[0]
    mask = recv_exact(conn, 4) if masked else b"\x00\x00\x00\x00"
    payload = recv_exact(conn, n) or b""
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def event_private(user_id="wxid_zhangwei", nickname="张伟", text="在吗？", seq=0) -> dict:
    return {
        "self_id": CONFIG["self_id"],
        "user_id": user_id,
        "group_id": "",
        "sender": {"user_id": user_id, "nickname": nickname},
        "time": now(),
        "post_type": "message",
        "message_id": f"mock-{now()}-{seq}",
        "message": [{"type": "text", "data": {"text": text}}],
        "raw_message": text,
        "show_content": text,
        "message_type": "private",
        "msgsource": "",
    }


def event_group(group_id="123456@chatroom", user_id="wxid_lina", nickname="李娜",
                text="@小助手 今天适合出门吗？", seq=0) -> dict:
    return {
        "self_id": CONFIG["self_id"],
        "user_id": user_id,
        "group_id": group_id,
        "sender": {"user_id": user_id, "nickname": nickname},
        "time": now(),
        "post_type": "message",
        "message_id": f"mock-{now()}-{seq}",
        "message": [
            {"type": "at", "data": {"qq": CONFIG["self_id"]}},
            {"type": "text", "data": {"text": text}},
        ],
        "raw_message": text,
        "show_content": text,
        "message_type": "group",
        "msgsource": "",
    }


DEMO_EVENTS = [
    event_private("wxid_zhangwei", "张伟", "在吗？最近那个方案想听听你的意见", 1),
    event_group("123456@chatroom", "wxid_lina", "李娜", "@小助手 今天适合出门吗？", 2),
    event_private("wxid_zhangwei", "张伟", "顺便帮我总结一下要点", 3),
]


def demo_loop(delay: float = 2.0) -> None:
    time.sleep(0.5)
    for ev in DEMO_EVENTS:
        broadcast(ev)
        print(f"[mock] pushed {ev['message_type']} event from {ev['sender']['nickname']}", flush=True)
        time.sleep(delay)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet
        pass

    # ---------- helpers ----------
    def json_response(self, status: int, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def authorized(self) -> bool:
        token = self.headers.get("Authorization", "")
        if token.startswith("Bearer "):
            token = token[7:]
        return CONFIG["token"] == "" or token == CONFIG["token"]

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    # ---------- HTTP ----------
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            self.handle_ws()
            return
        if path == "/health":
            with STATE["lock"]:
                clients = len(STATE["clients"])
            self.json_response(200, {
                "status": "ok",
                "self_id": CONFIG["self_id"],
                "ws_clients": clients,
                "sent": len(STATE["sent"]),
                "actions": STATE["received_actions"],
            })
            return
        self.json_response(404, {"status": "not_found"})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.read_body()
        if path in ("/send_private_msg", "/send_group_msg"):
            if not self.authorized():
                self.json_response(401, {"status": "failed", "error": "unauthorized"})
                return
            try:
                payload = json.loads(body.decode() or "{}")
            except json.JSONDecodeError:
                self.json_response(400, {"status": "failed", "error": "invalid json"})
                return
            entry = {
                "endpoint": path,
                "at": now(),
                "payload": payload,
            }
            log_sent(entry)
            target = payload.get("group_id") or payload.get("user_id") or "?"
            print(f"[mock] sent -> {path.split('_', 2)[-1]} {target}: {payload.get('message')}", flush=True)
            self.json_response(200, {"status": "ok", "data": {"message_id": f"sent-{uuid.uuid4().hex[:8]}"}})
            return
        if path == "/inject":
            try:
                payload = json.loads(body.decode() or "{}")
            except json.JSONDecodeError:
                self.json_response(400, {"status": "failed", "error": "invalid json"})
                return
            count = len(payload) if isinstance(payload, list) else 1
            events = payload if isinstance(payload, list) else [payload]
            for ev in events:
                broadcast(ev)
            self.json_response(200, {"status": "ok", "pushed": count})
            return
        if path == "/demo":
            threading.Thread(target=demo_loop, daemon=True).start()
            self.json_response(200, {"status": "ok"})
            return
        self.json_response(404, {"status": "not_found"})

    # ---------- WebSocket ----------
    def handle_ws(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.wfile.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode()
        )
        self.wfile.flush()
        self.close_connection = False
        conn = self.connection
        with STATE["lock"]:
            STATE["clients"].add(conn)
        print(f"[mock] ws client {self.client_address} connected", flush=True)
        try:
            while True:
                frame = ws_recv(conn)
                if frame is None:
                    break
                opcode, payload = frame
                if opcode == 0x8:  # close
                    try:
                        conn.sendall(ws_frame(b"", 0x8))
                    except OSError:
                        pass
                    break
                if opcode == 0x9:  # ping
                    conn.sendall(ws_frame(payload, 0xA))
                    continue
                if opcode != 0x1:
                    continue
                STATE["received_actions"] += 1
                try:
                    action = json.loads(payload.decode())
                except json.JSONDecodeError:
                    continue
                name = action.get("action")
                echo = action.get("echo", "")
                params = action.get("params") or {}
                print(f"[mock] ws action {name} {params}", flush=True)
                if name == "get_login_info":
                    ws_send(conn, {"echo": echo, "status": "ok",
                                   "data": {"user_id": CONFIG["self_id"], "nickname": "AI 助手"}})
                elif name == "get_group_member_info":
                    ws_send(conn, {"echo": echo, "status": "ok",
                                   "data": {"nickname": params.get("user_id", "成员")}})
                elif name in ("send_private_msg", "send_group_msg"):
                    log_sent({"endpoint": "/ws:" + name, "at": now(), "payload": params})
                    ws_send(conn, {"echo": echo, "status": "ok", "data": {"message_id": f"ws-{uuid.uuid4().hex[:8]}"}})
        finally:
            with STATE["lock"]:
                STATE["clients"].discard(conn)
            try:
                conn.close()
            except OSError:
                pass
            print(f"[mock] ws client {self.client_address} disconnected", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=58080)
    parser.add_argument("--token", default=os.environ.get("ONEBOT_TOKEN", "wechatai-local-token"))
    parser.add_argument("--sent-log", default="/tmp/wechatai-mock-sent.jsonl")
    parser.add_argument("--demo", action="store_true", help="push demo conversations when a WS client connects")
    args = parser.parse_args()

    CONFIG["token"] = args.token
    CONFIG["sent_log"] = args.sent_log
    try:
        os.remove(args.sent_log)
    except OSError:
        pass

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"[mock] listening on http://127.0.0.1:{args.port} (ws /ws), token={'set' if args.token else 'none'}", flush=True)

    if args.demo:
        def auto_demo():
            # Wait until the app connects, then push the demo script.
            for _ in range(120):
                with STATE["lock"]:
                    if STATE["clients"]:
                        break
                time.sleep(0.5)
            time.sleep(1.0)
            demo_loop()
        threading.Thread(target=auto_demo, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mock] bye", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
