from __future__ import annotations

import hashlib
import hmac
from pathlib import Path
import time


class RequestSigner:
    def __init__(self, secret_file: Path):
        secret = secret_file.read_bytes().strip()
        if not 32 <= len(secret) <= 4096:
            raise ValueError("local provider shared secret is invalid")
        self._secret = secret

    def headers(
        self,
        *,
        method: str,
        path: str,
        body: bytes,
        request_id: str,
        timestamp: int | None = None,
    ) -> dict[str, str]:
        timestamp = int(time.time()) if timestamp is None else timestamp
        message = b"\n".join(
            [
                str(timestamp).encode(),
                request_id.encode(),
                method.upper().encode(),
                path.encode(),
                body,
            ]
        )
        digest = hmac.new(self._secret, message, hashlib.sha256).hexdigest()
        return {
            "Content-Type": "application/json",
            "X-Lrail-Timestamp": str(timestamp),
            "X-Lrail-Request-Id": request_id,
            "X-Lrail-Signature": f"sha256={digest}",
        }
