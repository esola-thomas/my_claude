"""Stub for litellm (health, models) and the Copilot catalog, used by smoke tests."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
catalog = open(sys.argv[2], encoding="utf-8").read().encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/health/readiness"):
            body = b'{"status":"healthy"}'
        elif self.path.startswith("/v1/models"):
            body = json.dumps({"data": [{"id": "claude-opus-primary"}]}).encode()
        elif self.path.startswith("/models"):
            body = catalog
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
