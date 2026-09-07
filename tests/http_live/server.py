"""Local HTTP wire behavior used only by the real-client contract suite."""
import json
import select
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

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


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(json.dumps({"port": server.server_port}), flush=True)
try:
    server.serve_forever()
finally:
    server.server_close()
