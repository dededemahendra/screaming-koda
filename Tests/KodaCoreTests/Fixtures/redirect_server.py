#!/usr/bin/env python3
"""Tiny fixture server for exercising a real HTTP 301 redirect end to end.

`python3 -m http.server` (used by the rest of the fixture suite) can only serve
static files and cannot emit a redirect, so this is a minimal
`BaseHTTPRequestHandler` subclass instead: one path answers 301 with a
`Location` header, one path answers 200 with a small HTML page, everything
else answers 404. Invoked as `redirect_server.py <port>`.
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TARGET_BODY = b"<html><head><title>Redirect Target</title></head><body>Landed</body></html>"


class RedirectHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect-me":
            self.send_response(301)
            self.send_header("Location", "/target.html")
            self.end_headers()
        elif self.path == "/target.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(TARGET_BODY)))
            self.end_headers()
            self.wfile.write(TARGET_BODY)
        else:
            # Includes /robots.txt: a 404 there means "no robots.txt", i.e. allow-all.
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # keep test output quiet; FixtureServer already redirects stderr


if __name__ == "__main__":
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), RedirectHandler).serve_forever()
