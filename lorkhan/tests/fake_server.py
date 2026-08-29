"""Test-only fixture-driven LORKHAN loopback server.

The server refuses non-loopback bind addresses. Recorded diagnostics contain only method/path,
status, byte count, and a token fingerprint; authorization and bodies are never retained.
"""
from __future__ import annotations

import hashlib
import http.server
import ipaddress
import json
import socket
import threading
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "lorkhan/fixtures/v1/valid"
MAX_JSON = 2 * 1024 * 1024
MEDIA = b"WAVE"
MEDIA_HASH = hashlib.sha256(MEDIA).hexdigest()


def fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))["instance"]

@dataclass
class State:
    token: str = "fixture-pairing-token-not-a-real-secret"
    records: list[dict[str, Any]] = field(default_factory=list)
    sessions: dict[str, int] = field(default_factory=dict)
    idempotency: dict[str, bytes] = field(default_factory=dict)
    restart_epoch: int = 0
    disconnected: bool = False

class FakeServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, address: tuple[str, int]):
        host = ipaddress.ip_address(address[0])
        if not host.is_loopback:
            raise ValueError("test fake server may bind only to an IP loopback literal")
        self.state = State()
        super().__init__(address, Handler)

class Handler(http.server.BaseHTTPRequestHandler):
    server: FakeServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        pass

    def record(self, status: int, size: int) -> None:
        auth = self.headers.get("Authorization", "")
        fingerprint = hashlib.sha256(auth.encode()).hexdigest()[:12] if auth else "absent"
        self.server.state.records.append({"method": self.command, "path": self.path.split("?", 1)[0],
                                          "status": status, "bytes": size, "token_fingerprint": fingerprint})

    def send_bytes(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.record(status, len(body))

    def send_json(self, status: int, value: Any) -> None:
        self.send_bytes(status, json.dumps(value, sort_keys=True, separators=(",", ":")).encode(),
                        "application/json; charset=utf-8")

    def error(self, status: int, code: str) -> None:
        self.send_json(status, {"schema":"lorkhan.error.v1", "code":code, "message":"Request rejected",
                                "correlation_id":"00000000-0000-4000-8000-000000000099", "retriable":False})

    def authorized(self) -> bool:
        if self.headers.get("Authorization") != "Bearer " + self.server.state.token:
            self.error(401, "unauthorized")
            return False
        return True

    def read_json(self) -> tuple[bytes, Any] | None:
        if self.headers.get("Content-Type", "").lower() != "application/json; charset=utf-8":
            self.error(415, "invalid_schema")
            return None
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            self.error(400, "invalid_schema")
            return None
        if length < 0 or length > MAX_JSON:
            self.error(413, "payload_too_large")
            return None
        raw = self.rfile.read(length)
        try:
            return raw, json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.error(400, "invalid_schema")
            return None

    def require_idempotency(self, raw: bytes, message_id: str) -> bool:
        key = self.headers.get("Idempotency-Key")
        if key != message_id:
            self.error(400, "invalid_schema")
            return False
        previous = self.server.state.idempotency.get(key)
        if previous is not None and previous != raw:
            self.error(409, "duplicate_conflict")
            return False
        self.server.state.idempotency[key] = raw
        return True

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/v1/health":
            self.send_json(200, fixture("health.json")); return
        if not self.authorized(): return
        if parsed.path == "/api/v1/events":
            query = urllib.parse.parse_qs(parsed.query)
            wait = int(query.get("wait_ms", ["0"])[0])
            if wait > 15000:
                self.error(400, "invalid_schema"); return
            if wait == 1:
                time.sleep(0.03)
            events = fixture("events.json")
            scenario = query.get("scenario", [""])[0]
            if scenario == "duplicate": events["events"].append(dict(events["events"][0]))
            if scenario == "gap": events["events"][1]["sequence"] = 3
            self.send_json(200, events); return
        if parsed.path.startswith("/api/v1/media/"):
            if parsed.path != "/api/v1/media/00000000-0000-4000-8000-000000000013":
                self.error(404, "media_unavailable"); return
            self.send_bytes(200, MEDIA, "audio/wav"); return
        self.error(404, "invalid_schema")

    def do_POST(self) -> None:
        if not self.authorized(): return
        parsed = urllib.parse.urlparse(self.path)
        data = self.read_json()
        if data is None: return
        raw, body = data
        if not isinstance(body, dict):
            self.error(400, "invalid_schema"); return
        idempotency_id = body.get("message_id")
        if not isinstance(idempotency_id, str):
            self.error(400, "invalid_schema"); return
        if not self.require_idempotency(raw, idempotency_id): return
        if parsed.path == "/api/v1/sessions":
            session = "00000000-0000-4000-8000-000000000007"
            self.server.state.sessions[session] = body.get("generation", -1)
            accepted = fixture("session-accepted.json"); accepted["message_id"] = body["message_id"]
            self.send_json(201, accepted); return
        if parsed.path == "/api/v1/action-results":
            accepted = fixture("action-result-accepted.json")
            for key in ("message_id", "request_id", "action_id", "turn_id", "session_id", "generation", "status"):
                accepted[key] = body[key]
            self.send_json(200, accepted); return
        session = body.get("session_id")
        generation = body.get("generation")
        if session not in self.server.state.sessions:
            self.error(404, "unknown_session"); return
        if generation != self.server.state.sessions[session]:
            self.error(409, "stale_generation"); return
        if parsed.path == "/api/v1/turns":
            accepted = fixture("turn-accepted.json")
            for key in ("message_id", "request_id", "turn_id", "session_id", "generation"): accepted[key] = body[key]
            self.send_json(202, accepted); return
        if parsed.path == "/api/v1/interruptions":
            accepted = fixture("interruption-accepted.json")
            for key in ("message_id", "request_id", "turn_id", "session_id", "generation"): accepted[key] = body[key]
            self.send_json(202, accepted); return
        self.error(404, "not_found")

    def do_DELETE(self) -> None:
        if not self.authorized(): return
        parsed = urllib.parse.urlparse(self.path)
        prefix = "/api/v1/sessions/"
        if not parsed.path.startswith(prefix): self.error(404, "not_found"); return
        session = parsed.path[len(prefix):]
        key = self.headers.get("Idempotency-Key")
        if not key: self.error(422, "invalid_idempotency_key"); return
        generation = self.server.state.sessions.pop(session, None)
        if generation is None: self.error(404, "unknown_session"); return
        self.send_json(200, {"schema":"lorkhan.session.ended.v1", "request_id":key, "session_id":session,
                             "generation":generation, "ended":True})

class RunningServer:
    def __enter__(self) -> FakeServer:
        self.server = FakeServer(("127.0.0.1", 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self.server

    def __exit__(self, *args: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
