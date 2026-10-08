#!/usr/bin/env python3
"""ÆSTHETIC JOURNEY web — http://localhost:1111"""

from __future__ import annotations

import mimetypes
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent
PORT = int(os.environ.get("PORT", "1111"))
HOST = os.environ.get("HOST", "127.0.0.1")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[share-web] {self.address_string()} - {fmt % args}")

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(urlparse(self.path).path)

        if path == "/health":
            self._send(200, b"ok", "text/plain; charset=utf-8")
            return

        # Marketing homepage (coming soon for now)
        if path == "/" or path == "/home" or path == "/index.html" or path == "/coming-soon":
            self._file(ROOT / "index.html")
            return

        # Full marketing preview (kept for later)
        if path == "/preview" or path == "/home.html":
            self._file(ROOT / "home.html")
            return

        # Share landing SPA
        if path.startswith("/share/") or path == "/share" or path == "/share.html":
            self._file(ROOT / "share.html")
            return

        # Static assets
        rel = path.lstrip("/")
        candidate = (ROOT / rel).resolve()
        if not str(candidate).startswith(str(ROOT)) or not candidate.is_file():
            self._send(404, b"Not found", "text/plain; charset=utf-8")
            return
        self._file(candidate)

    def _file(self, file_path: Path) -> None:
        data = file_path.read_bytes()
        ctype, _ = mimetypes.guess_type(str(file_path))
        if file_path.suffix == ".js":
            ctype = "text/javascript; charset=utf-8"
        elif file_path.suffix == ".css":
            ctype = "text/css; charset=utf-8"
        elif file_path.suffix == ".html":
            ctype = "text/html; charset=utf-8"
        self._send(200, data, ctype or "application/octet-stream")

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"ÆSTHETIC JOURNEY web → http://localhost:{PORT}")
    print(f"  home:  http://localhost:{PORT}/")
    print(f"  share: http://localhost:{PORT}/share/<shareId>")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
