#!/usr/bin/env python3
import copy
import json
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


models = {
    "fake/loaded": {
        "id": "fake/loaded",
        "aliases": [],
        "tags": ["integration"],
        "object": "model",
        "owned_by": "llamacpp",
        "created": 1,
        "status": {
            "value": "loaded",
            "args": ["llama-server", "--alias", "fake/loaded"],
            "preset": "[fake/loaded]\nctx-size = 8192\n\n",
        },
        "architecture": {
            "input_modalities": ["text", "image"],
            "output_modalities": ["text"],
        },
        "source": "preset",
        "can_remove": False,
        "meta": {
            "n_ctx": 8192,
            "n_params": 1000000,
            "size": 1048576,
        },
    },
    "fake/unloaded": {
        "id": "fake/unloaded",
        "aliases": [],
        "tags": [],
        "object": "model",
        "owned_by": "llamacpp",
        "created": 1,
        "status": {
            "value": "unloaded",
            "args": ["llama-server", "--alias", "fake/unloaded"],
        },
        "architecture": {
            "input_modalities": ["text"],
            "output_modalities": ["text"],
        },
        "source": "cache",
        "can_remove": True,
    },
    "fake/failing": {
        "id": "fake/failing",
        "aliases": [],
        "tags": [],
        "object": "model",
        "owned_by": "llamacpp",
        "created": 1,
        "status": {
            "value": "unloaded",
            "args": ["llama-server", "--alias", "fake/failing"],
        },
        "architecture": {
            "input_modalities": ["text"],
            "output_modalities": ["text"],
        },
        "source": "preset",
        "can_remove": False,
    },
}
state_lock = threading.RLock()
subscribers = []
subscribers_lock = threading.Lock()
record_lock = threading.Lock()


def record(value):
    with record_lock:
        print(json.dumps(value, separators=(",", ":")), flush=True)


def broadcast(event, model, data=None):
    value = {"model": model, "event": event}
    if data is not None:
        value["data"] = data
    with subscribers_lock:
        current = list(subscribers)
    for subscriber in current:
        subscriber.put(value)


def model_catalog():
    with state_lock:
        return {
            "data": [copy.deepcopy(value) for value in models.values()],
            "object": "list",
        }


def delayed_load(model):
    time.sleep(0.04)
    with state_lock:
        entry = models.get(model)
        if not entry or entry["status"]["value"] != "loading":
            return
        entry["status"]["progress"] = {
            "stages": ["text_model", "mmproj_model"],
            "current": "text_model",
            "value": 0.5,
        }
    broadcast("status_change", model, {
        "status": "loading",
        "progress": {
            "stages": ["text_model", "mmproj_model"],
            "current": "text_model",
            "value": 0.5,
        },
    })
    time.sleep(0.04)
    with state_lock:
        entry = models.get(model)
        if not entry or entry["status"]["value"] != "loading":
            return
        if model == "fake/failing":
            entry["status"] = {
                "value": "unloaded",
                "args": ["llama-server", "--alias", model],
                "failed": True,
                "exit_code": 42,
            }
            failed = True
        else:
            failed = False
            entry["status"] = {
                "value": "loaded",
                "args": ["llama-server", "--alias", model],
            }
            entry["meta"] = {"n_ctx": 4096, "n_params": 500000, "size": 524288}
            loaded_meta = copy.deepcopy(entry["meta"])
    if failed:
        broadcast("status_change", model, {"status": "unloaded", "exit_code": 42})
        return
    broadcast("status_change", model, {
        "status": "loaded",
        "info": {"meta": loaded_meta},
    })


def delayed_unload(model):
    time.sleep(0.04)
    with state_lock:
        entry = models.get(model)
        if not entry:
            return
        entry["status"] = {
            "value": "unloaded",
            "args": ["llama-server", "--alias", model],
            "exit_code": 0,
        }
        entry.pop("meta", None)
    broadcast("status_change", model, {"status": "unloaded", "exit_code": 0})


def delayed_download(model):
    time.sleep(0.04)
    if model == "fake/failing-download":
        with state_lock:
            entry = models.get(model)
            if not entry or entry["status"]["value"] != "downloading":
                return
            models.pop(model)
        broadcast("download_failed", model, {"error": "download failed"})
        return
    progress = {
        "progress": {
            "https://fake.invalid/model.gguf": {"done": 256, "total": 512},
            "https://fake.invalid/mmproj.gguf": {"done": 256, "total": 512},
        },
    }
    with state_lock:
        entry = models.get(model)
        if not entry or entry["status"]["value"] != "downloading":
            return
    broadcast("download_progress", model, progress)
    time.sleep(0.25)
    with state_lock:
        entry = models.get(model)
        if not entry or entry["status"]["value"] != "downloading":
            return
        entry["status"] = {
            "value": "unloaded",
            "args": ["llama-server", "--alias", model],
        }
    broadcast("download_finished", model)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def _request(self, body=None):
        return {
            "type": "request",
            "method": self.command,
            "path": self.path,
            "headers": {key.lower(): value for key, value in self.headers.items()},
            "body": body,
        }

    def _read_json(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except Exception as error:
            return {"_decode_error": str(error), "_raw": raw.decode("utf-8", "replace")}

    def _json(self, value, status=200):
        data = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def _error(self, status, message, error_type="invalid_request_error"):
        self._json({"error": {
            "code": status,
            "message": message,
            "type": error_type,
        }}, status)

    def do_GET(self):
        record(self._request())
        path = urlsplit(self.path).path
        if path in ("/models", "/v1/models"):
            self._json(model_catalog())
            return
        if path == "/health":
            self._json({"status": "ok"})
            return
        if path == "/models/sse":
            self._events()
            return
        self._error(404, "File Not Found", "not_found_error")

    def _events(self):
        subscriber = queue.Queue()
        with subscribers_lock:
            subscribers.append(subscriber)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        try:
            while True:
                try:
                    event = subscriber.get(timeout=0.1)
                except queue.Empty:
                    continue
                data = "data: " + json.dumps(event, separators=(",", ":")) + "\n\n"
                self.wfile.write(data.encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with subscribers_lock:
                if subscriber in subscribers:
                    subscribers.remove(subscriber)
            self.close_connection = True

    def do_POST(self):
        body = self._read_json()
        record(self._request(body))
        path = urlsplit(self.path).path
        if path == "/models/load":
            self._load(body)
            return
        if path == "/models/unload":
            self._unload(body)
            return
        if path == "/models":
            self._download(body)
            return
        if path == "/v1/chat/completions":
            self._chat(body)
            return
        self._error(404, "File Not Found", "not_found_error")

    def _load(self, body):
        model = body.get("model") if isinstance(body, dict) else None
        with state_lock:
            entry = models.get(model)
            if not entry:
                self._error(404, "model is not found", "not_found_error")
                return
            if entry["status"]["value"] in ("loading", "loaded", "sleeping"):
                self._error(400, "model is already running")
                return
            entry["status"] = {
                "value": "loading",
                "args": ["llama-server", "--alias", model],
            }
        broadcast("model_status", model, {"status": "loading"})
        threading.Thread(target=delayed_load, args=(model,), daemon=True).start()
        self._json({"success": True})

    def _unload(self, body):
        model = body.get("model") if isinstance(body, dict) else None
        with state_lock:
            entry = models.get(model)
            if not entry:
                self._error(400, "model is not found")
                return
            status = entry["status"]["value"]
            if status not in ("loading", "loaded", "sleeping", "downloading"):
                self._error(400, "model is not running")
                return
        threading.Thread(target=delayed_unload, args=(model,), daemon=True).start()
        self._json({"success": True})

    def _download(self, body):
        model = body.get("model") if isinstance(body, dict) else None
        if not isinstance(model, str) or not model:
            self._error(400, "model must be a non-empty string")
            return
        with state_lock:
            if model in models:
                self._error(400, "model already exists")
                return
            models[model] = {
                "id": model,
                "aliases": [],
                "tags": [],
                "object": "model",
                "owned_by": "llamacpp",
                "created": 1,
                "status": {
                    "value": "downloading",
                    "args": ["llama-server", "--alias", model],
                },
                "architecture": {
                    "input_modalities": ["text"],
                    "output_modalities": ["text"],
                },
                "source": "cache",
                "can_remove": True,
            }
        broadcast("model_status", model, {"status": "downloading"})
        threading.Thread(target=delayed_download, args=(model,), daemon=True).start()
        self._json({"success": True})

    def _chat(self, body):
        model = body.get("model") if isinstance(body, dict) else None
        with state_lock:
            entry = models.get(model)
            status = entry and entry["status"]["value"]
            if entry and status == "unloaded":
                entry["status"] = {
                    "value": "loading",
                    "args": ["llama-server", "--alias", model],
                }
                status = "loading"
                broadcast("model_status", model, {"status": "loading"})
                threading.Thread(
                    target=delayed_load, args=(model,), daemon=True
                ).start()
        if status == "loading":
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                with state_lock:
                    entry = models.get(model)
                    status = entry and entry["status"]["value"]
                if status != "loading":
                    break
                time.sleep(0.005)
        loaded = status in ("loaded", "sleeping")
        if not loaded:
            self._error(404, "model is not loaded", "not_found_error")
            return
        has_image = any(
            isinstance(content, list)
            and any(
                isinstance(block, dict)
                and block.get("type") == "image_url"
                and isinstance(block.get("image_url"), dict)
                and block["image_url"].get("url", "").startswith(
                    "data:image/png;base64,"
                )
                for block in content
            )
            for message in body.get("messages", [])
            if isinstance(message, dict)
            for content in [message.get("content")]
        )
        text = ("image ", "accepted") if has_image else ("fake ", "reply")
        chunks = [
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": None}, "finish_reason": None}],
            },
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {"reasoning_content": "checking the image"}, "finish_reason": None}],
            },
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {"content": text[0]}, "finish_reason": None}],
            },
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {"content": text[1]}, "finish_reason": None}],
            },
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7},
            },
        ]
        if body.get("return_progress") is True:
            chunks[1:1] = [
                {
                    "id": "chatcmpl-fake",
                    "object": "chat.completion.chunk",
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": {"role": "assistant", "content": None},
                        "finish_reason": None,
                    }],
                    "prompt_progress": {"total": 3, "cache": 0, "processed": 1, "time_ms": 10},
                    "timings": {
                        "cache_n": 0,
                        "prompt_n": 1,
                        "prompt_ms": 0.001,
                        "prompt_per_second": 1000000,
                        "predicted_n": 0,
                        "predicted_ms": 0,
                        "predicted_per_second": 0,
                    },
                },
                {
                    "id": "chatcmpl-fake",
                    "object": "chat.completion.chunk",
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": {"role": "assistant", "content": None},
                        "finish_reason": None,
                    }],
                    "prompt_progress": {"total": 3, "cache": 0, "processed": 3, "time_ms": 2000},
                    "timings": {
                        "cache_n": 0,
                        "prompt_n": 3,
                        "prompt_ms": 40,
                        "prompt_per_second": 75,
                        "predicted_n": 0,
                        "predicted_ms": 0,
                        "predicted_per_second": 0,
                    },
                },
            ]
        if body.get("timings_per_token") is True:
            rates = (0, 40, 45, 50)
            for predicted_n, (chunk, rate) in enumerate(
                zip(chunks[-4:], rates), start=1
            ):
                chunk["timings"] = {
                    "cache_n": 0,
                    "prompt_n": 3,
                    "prompt_ms": 40,
                    "prompt_per_second": 75,
                    "predicted_n": predicted_n,
                    "predicted_ms": (
                        (predicted_n - 1) * 1000 / rate + 1 if rate else 1
                    ),
                    "predicted_per_second": rate,
                }
        payload = "".join(
            "data: " + json.dumps(chunk, separators=(",", ":")) + "\n\n"
            for chunk in chunks
        ) + "data: [DONE]\n\n"
        data = payload.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        midpoint = len(data) // 2
        self.wfile.write(data[:midpoint])
        self.wfile.flush()
        time.sleep(0.02)
        self.wfile.write(data[midpoint:])
        self.wfile.flush()

    def do_DELETE(self):
        record(self._request())
        parsed = urlsplit(self.path)
        if parsed.path != "/models":
            self._error(404, "File Not Found", "not_found_error")
            return
        model = parse_qs(parsed.query).get("model", [None])[0]
        with state_lock:
            entry = models.get(model)
            if not entry:
                self._error(404, "model is not found", "not_found_error")
                return
            if not entry.get("can_remove"):
                self._error(400, "model is not removable")
                return
            del models[model]
        broadcast("model_remove", model)
        self._json({"success": True})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
record({"type": "ready", "port": server.server_address[1]})

try:
    server.serve_forever()
finally:
    server.server_close()
