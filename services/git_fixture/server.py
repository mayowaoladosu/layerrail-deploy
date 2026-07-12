from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import os
from pathlib import Path, PurePosixPath
import subprocess
from urllib.parse import urlsplit


USERNAME = os.environ.get("GIT_FIXTURE_USERNAME", "fixture-user")
PASSWORD = Path(
    os.environ.get("GIT_FIXTURE_PASSWORD_PATH", "/run/lrail-git-fixture/password")
).read_text(encoding="utf-8").strip()
MAX_BODY = 16 << 20


class Handler(BaseHTTPRequestHandler):
    server_version = "LayerRailGitFixture/1"

    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        self._handle()

    def log_message(self, _format: str, *_arguments: object) -> None:
        return

    def _handle(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if not self._authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="LayerRail E2E"')
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if not 0 <= length <= MAX_BODY or not self._valid_path(parsed.path):
            self.send_error(400)
            return
        body = self.rfile.read(length)
        environment = os.environ.copy()
        environment.update(
            GIT_PROJECT_ROOT="/repos",
            GIT_HTTP_EXPORT_ALL="1",
            PATH_INFO=parsed.path,
            QUERY_STRING=parsed.query,
            REQUEST_METHOD=self.command,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(length),
            REMOTE_USER=USERNAME,
            REMOTE_ADDR=self.client_address[0],
        )
        completed = subprocess.run(
            ["git", "http-backend"],
            input=body,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
            timeout=30,
            check=False,
        )
        if completed.returncode != 0:
            self.send_error(500)
            return
        separator = b"\r\n\r\n" if b"\r\n\r\n" in completed.stdout else b"\n\n"
        try:
            raw_headers, response = completed.stdout.split(separator, 1)
        except ValueError:
            self.send_error(500)
            return
        status = 200
        headers: list[tuple[str, str]] = []
        for raw in raw_headers.replace(b"\r\n", b"\n").splitlines():
            name, value = raw.decode("latin-1").split(":", 1)
            if name.lower() == "status":
                status = int(value.strip().split(" ", 1)[0])
            else:
                headers.append((name.strip(), value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(response)

    def _authorized(self) -> bool:
        expected = "Basic " + base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()
        return hmac.compare_digest(self.headers.get("Authorization", ""), expected)

    def _valid_path(self, value: str) -> bool:
        path = PurePosixPath(value)
        return (
            value.startswith("/")
            and "\\" not in value
            and ".." not in path.parts
            and any(part.endswith(".git") for part in path.parts)
        )


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
