"""Local HTTP wire behavior used only by the real-client contract suite."""
import json
import select
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer


class LoopbackHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # The wire fixture needs only its numeric loopback address, not DNS.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        token = self.headers.get("x-codex-turn-state")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("X-Codex-Turn-State", "synthetic-routing-state-" * 100)
        if token is None:
            self.send_header("Content-Length", "1")
            self.end_headers()
            self.close_connection = True
            return
        body = b"data: " + json.dumps({
            "type": "response.completed",
            "response": {
                "id": "synthetic-response",
                "status": "completed",
                "output": [{
                    "type": "message",
                    "id": "msg_reply",
                    "role": "assistant",
                    "status": "completed",
                    "content": [{"type": "output_text", "text": token, "annotations": []}],
                }],
            },
        }).encode() + b"\n\n"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/disconnect":
            self.close_connection = True
            return
        if self.path == "/headers":
            self.wfile.write(b"HTTP/1.1 100 Continue\r\nX-Transient: interim\r\n\r\n")
            body = b"first\n200"
        elif self.path == "/error":
            body = b'{"error":{"message":"limited"}}'
        elif self.path == "/large":
            body = json.dumps({"text": "x" * 4096}).encode()
        else:
            body = b'data: {"value":1}\r\n\r\n'
        self.send_response(429 if self.path == "/error" else 200)
        self.send_header("Content-Type", "text/event-stream" if self.path == "/stream" else "application/json")
        self.send_header("X-Request-Id", "final")
        self.send_header("X-Duplicate", "first")
        self.send_header("X-Duplicate", "last")
        if self.path != "/stream":
            self.send_header("Content-Length", str(len(body)))
        else:
            self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
            if self.path == "/stream":
                # Wait for the client's cancellation/EOF with a bounded deadline.
                if select.select([self.connection], [], [], 3)[0]:
                    self.connection.recv(1)
                self.close_connection = True
        except (BrokenPipeError, ConnectionResetError):
            pass


server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(json.dumps({"port": server.server_port}), flush=True)
try:
    server.serve_forever()
finally:
    server.server_close()
