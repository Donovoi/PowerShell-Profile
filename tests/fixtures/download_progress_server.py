"""Loopback-only, throttled HTTP fixture for progress and cancellation tests."""
import json
from pathlib import Path
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(sys.argv[1])
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", str(4 * 1024 * 1024))
        self.end_headers()

    def do_GET(self):
        with lock, (root / "requests.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps({"path": self.path}) + "\n")
        if "/missing/" in self.path:
            self.send_error(404)
            return
        if "/stall/" in self.path:
            time.sleep(8)
        size = (64 if "/cancel/" in self.path else 4) * 1024 * 1024
        self.send_response(200)
        if "/unknown/" not in self.path:
            self.send_header("Content-Length", str(size))
        try:
            self.end_headers()
            for _ in range(size // 65536):
                self.wfile.write(b"x" * 65536)
                self.wfile.flush()
                time.sleep(0.075)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
