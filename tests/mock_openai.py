#!/usr/bin/env python3
import json
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl


with open(sys.argv[1], "r", encoding="utf-8") as fixture_file:
    fixture = json.load(fixture_file)

steps = list(fixture.get("steps", []))
requests = []


def record(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        if self.headers.get("content-type", "").startswith("application/x-www-form-urlencoded"):
            body = dict(parse_qsl(raw.decode("utf-8", "replace"), keep_blank_values=True))
        else:
            try:
                body = json.loads(raw)
            except Exception as error:
                body = {"_decode_error": str(error), "_raw": raw.decode("utf-8", "replace")}
        received = {
            "method": "POST",
            "path": self.path,
            "headers": {key.lower(): value for key, value in self.headers.items()},
            "body": body,
        }
        requests.append(received)
        record({"type": "request", **received})

        if not steps:
            self._mismatch("unexpected request")
            return
        step = steps.pop(0)
        expected = step.get("expect", {})
        mismatch = self._compare(expected, received)
        if mismatch:
            self._mismatch(mismatch)
            return

        response = step.get("respond", {})
        status = int(response.get("status", 200))
        chunks = response.get("chunks")
        if chunks is None:
            chunks = [{"data": json.dumps(response.get("json", {}), separators=(",", ":"))}]
        encoded = [chunk.get("data", "").encode("utf-8") for chunk in chunks]
        self.send_response(status)
        headers = response.get("headers", {})
        for key, value in headers.items():
            self.send_header(key, value)
        if "content-length" not in {key.lower() for key in headers}:
            self.send_header("Content-Length", str(sum(len(value) for value in encoded)))
        self.end_headers()
        for chunk, data in zip(chunks, encoded):
            delay = chunk.get("delay_ms", 0)
            if delay:
                time.sleep(delay / 1000)
            try:
                self.wfile.write(data)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                record({"type": "disconnect"})
                break

    def _compare(self, expected, received):
        if expected.get("method", "POST") != received["method"]:
            return "method mismatch"
        if "path" in expected and expected["path"] != received["path"]:
            return "path mismatch"
        for key, value in expected.get("headers", {}).items():
            if received["headers"].get(key.lower()) != value:
                return f"header mismatch: {key}"
        if "body" in expected and expected["body"] != received["body"]:
            return "body mismatch"
        for key, value in expected.get("body_contains", {}).items():
            if received["body"].get(key) != value:
                return f"body field mismatch: {key}"
        return None

    def _mismatch(self, message):
        record({"type": "mismatch", "message": message})
        data = json.dumps({"error": {"message": message}}).encode("utf-8")
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
record({"type": "ready", "port": server.server_address[1]})


def stop(_signum, _frame):
    server.shutdown()


signal.signal(signal.SIGTERM, stop)
try:
    server.serve_forever()
finally:
    record({"type": "stopped", "remaining": len(steps)})
    server.server_close()
