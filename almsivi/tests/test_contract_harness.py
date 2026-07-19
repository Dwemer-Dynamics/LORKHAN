from __future__ import annotations

import copy
import hashlib
import http.client
import json
import socket
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_server import MEDIA, MEDIA_HASH, FakeServer, RunningServer, fixture

TOKEN = "fixture-pairing-token-not-a-real-secret"

class ContractHarnessTests(unittest.TestCase):
    def request(self, server, method, path, body=None, *, token=TOKEN, content_type="application/json; charset=utf-8", key=None, timeout=1):
        connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=timeout)
        raw = None if body is None else (body if isinstance(body, bytes) else json.dumps(body, sort_keys=True, separators=(",", ":")).encode())
        headers = {"Authorization": "Bearer " + token}
        if raw is not None:
            headers["Content-Type"] = content_type
            headers["Content-Length"] = str(len(raw))
            if key is not None: headers["Idempotency-Key"] = key
        connection.request(method, path, body=raw, headers=headers)
        response = connection.getresponse()
        data = response.read()
        response_headers = dict(response.getheaders())
        connection.close()
        return response.status, response_headers, data

    def json_request(self, *args, **kwargs):
        status, headers, raw = self.request(*args, **kwargs)
        return status, headers, json.loads(raw)

    def start_session(self, server):
        body = fixture("session-init.json")
        status, _, response = self.json_request(server, "POST", "/api/v1/sessions", body, key=body["message_id"])
        self.assertEqual(status, 201)
        return response["session_id"]

    def test_health_auth_content_type_and_redaction(self):
        with RunningServer() as server:
            status, headers, body = self.json_request(server, "GET", "/api/v1/health")
            self.assertEqual((status, headers["Content-Type"], body), (200, "application/json; charset=utf-8", fixture("health.json")))
            self.assertEqual(self.json_request(server, "GET", "/api/v1/health", token="wrong")[0], 401)
            rendered = json.dumps(server.state.records)
            self.assertNotIn(TOKEN, rendered)
            self.assertNotIn("Authorization", rendered)
            self.assertTrue(all(set(record) == {"method", "path", "status", "bytes", "token_fingerprint"} for record in server.state.records))

    def test_session_turn_idempotency_wrong_type_and_stale_generation(self):
        with RunningServer() as server:
            self.start_session(server)
            turn = fixture("turn.json")
            status, _, _ = self.json_request(server, "POST", "/api/v1/turns", turn, key=turn["message_id"])
            self.assertEqual(status, 202)
            self.assertEqual(self.json_request(server, "POST", "/api/v1/turns", turn, key=turn["message_id"])[0], 202)
            changed = copy.deepcopy(turn); changed["input"]["text"] = "changed"
            self.assertEqual(self.json_request(server, "POST", "/api/v1/turns", changed, key=turn["message_id"])[2]["code"], "duplicate_conflict")
            stale = copy.deepcopy(turn); stale["message_id"] = "00000000-0000-4000-8000-000000000030"; stale["generation"] = 6
            self.assertEqual(self.json_request(server, "POST", "/api/v1/turns", stale, key=stale["message_id"])[2]["code"], "stale_generation")
            wrong = copy.deepcopy(turn); wrong["message_id"] = "00000000-0000-4000-8000-000000000031"; wrong["generation"] = "7"
            self.assertEqual(self.json_request(server, "POST", "/api/v1/turns", wrong, key=wrong["message_id"])[2]["code"], "stale_generation")

    def test_events_order_duplicates_gaps_poll_cap_and_timeout(self):
        with RunningServer() as server:
            events = self.json_request(server, "GET", "/api/v1/events?session_id=x&after=0&wait_ms=0")[2]["events"]
            self.assertEqual([item["sequence"] for item in events], [1, 2])
            duplicate = self.json_request(server, "GET", "/api/v1/events?scenario=duplicate&wait_ms=0")[2]["events"]
            accepted = {(item["session_id"], item["sequence"], item["message_id"]) for item in duplicate}
            self.assertEqual(len(accepted), 2)
            gap = self.json_request(server, "GET", "/api/v1/events?scenario=gap&wait_ms=0")[2]["events"]
            self.assertNotEqual(gap[1]["sequence"], gap[0]["sequence"] + 1)
            self.assertEqual(self.json_request(server, "GET", "/api/v1/events?wait_ms=15001")[0], 400)
            connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=0.001)
            try:
                with self.assertRaises((TimeoutError, socket.timeout)):
                    connection.request("GET", "/api/v1/events?wait_ms=1", headers={"Authorization": "Bearer " + TOKEN})
                    connection.getresponse()
            finally:
                connection.close()

    def test_action_result_interruption_and_restart_unknown_session(self):
        with RunningServer() as server:
            self.start_session(server)
            for endpoint, name in (("action-results", "action-result.json"), ("interruptions", "interrupt.json")):
                body = fixture(name)
                self.assertEqual(self.json_request(server, "POST", "/api/v1/" + endpoint, body, key=body["message_id"])[0], 200)
        with RunningServer() as restarted:
            turn = fixture("turn.json")
            status, _, body = self.json_request(restarted, "POST", "/api/v1/turns", turn, key=turn["message_id"])
            self.assertEqual((status, body["code"]), (404, "unknown_session"))

    def test_media_bytes_hash_content_type_and_opaque_route(self):
        with RunningServer() as server:
            status, headers, body = self.request(server, "GET", "/api/v1/media/00000000-0000-4000-8000-000000000013")
            self.assertEqual((status, headers["Content-Type"], body), (200, "audio/wav", MEDIA))
            self.assertEqual(hashlib.sha256(body).hexdigest(), MEDIA_HASH)
            self.assertEqual(self.json_request(server, "GET", "/api/v1/media/../../secret")[2]["code"], "media_unavailable")

    def test_malformed_oversized_wrong_content_type_and_disconnect(self):
        with RunningServer() as server:
            self.assertEqual(self.json_request(server, "POST", "/api/v1/sessions", b"{", key="x")[0], 400)
            self.assertEqual(self.json_request(server, "POST", "/api/v1/sessions", {}, content_type="text/plain", key="x")[0], 415)
            connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=1)
            connection.request("POST", "/api/v1/sessions", headers={"Authorization":"Bearer " + TOKEN, "Content-Type":"application/json; charset=utf-8", "Content-Length":str(2 * 1024 * 1024 + 1)})
            self.assertEqual(connection.getresponse().status, 413)
            connection.close()
            port = server.server_address[1]
        with self.assertRaises((ConnectionRefusedError, socket.timeout, OSError)):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.1); connection.request("GET", "/api/v1/health"); connection.getresponse()

    def test_non_loopback_bind_is_refused(self):
        with self.assertRaisesRegex(ValueError, "loopback"):
            FakeServer(("0.0.0.0", 0))

if __name__ == "__main__":
    unittest.main()
