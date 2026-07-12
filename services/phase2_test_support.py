from __future__ import annotations

import base64
import hashlib
import hmac
import socket
import subprocess
import tempfile
import time
from typing import BinaryIO
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4


class Forward:
    def __init__(
        self,
        *,
        kubectl: list[str],
        resource: str,
        remote_port: int,
    ) -> None:
        self._kubectl = kubectl
        self._resource = resource
        self._remote_port = remote_port
        self._log: BinaryIO | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self.port = self._free_port()

    def __enter__(self) -> "Forward":
        self._log = tempfile.TemporaryFile()
        self._process = subprocess.Popen(
            [
                *self._kubectl,
                "port-forward",
                "-n",
                "lrail-system",
                self._resource,
                f"{self.port}:{self._remote_port}",
                "--address=127.0.0.1",
            ],
            stdin=subprocess.DEVNULL,
            stdout=self._log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                self._raise_failure("port-forward exited before becoming ready")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    return self
            except OSError:
                time.sleep(0.1)
        self._raise_failure("port-forward did not become ready")

    def __exit__(self, *_args: object) -> None:
        if self._process is not None and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=5)
        if self._log is not None:
            self._log.close()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def _raise_failure(self, message: str) -> None:
        details = ""
        if self._log is not None:
            self._log.seek(0)
            details = self._log.read().decode(errors="replace").strip()
        raise RuntimeError(f"{message}: {details}")

    def _free_port(self) -> int:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return int(listener.getsockname()[1])


def request(
    method: str,
    url: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    value = Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urlopen(value, timeout=20) as response:
            return response.status, dict(response.headers), response.read()
    except HTTPError as error:
        return error.code, dict(error.headers), error.read()


def assert_status(actual: int, expected: int | set[int], context: str) -> None:
    values = {expected} if isinstance(expected, int) else expected
    if actual not in values:
        raise AssertionError(f"{context}: expected {sorted(values)}, received {actual}")


def admin_headers(
    secret: bytes,
    method: str,
    path: str,
    body: bytes,
    *,
    content_type: str = "application/json",
) -> dict[str, str]:
    timestamp = str(int(time.time()))
    request_id = str(uuid4())
    message = b"\n".join(
        [timestamp.encode(), request_id.encode(), method.encode(), path.encode(), body]
    )
    signature = hmac.new(secret, message, hashlib.sha256).hexdigest()
    return {
        "Content-Type": content_type,
        "X-Lrail-Timestamp": timestamp,
        "X-Lrail-Request-Id": request_id,
        "X-Lrail-Signature": f"sha256={signature}",
    }


def kubectl_secret(kubectl: list[str], name: str, key: str) -> bytes:
    encoded = subprocess.check_output(
        [
            *kubectl,
            "get",
            "secret",
            name,
            "-n",
            "lrail-system",
            "-o",
            f"jsonpath={{.data.{key}}}",
        ]
    )
    return base64.b64decode(encoded)
