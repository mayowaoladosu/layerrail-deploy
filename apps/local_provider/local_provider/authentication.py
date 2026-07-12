from __future__ import annotations

import hashlib
import hmac
from pathlib import Path
import time
from typing import Mapping
from uuid import UUID


class RequestSigner:
    MAX_CLOCK_SKEW_SECONDS = 60

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

    def valid(
        self,
        *,
        method: str,
        path: str,
        body: bytes,
        headers: Mapping[str, str],
        now: int | None = None,
    ) -> bool:
        try:
            timestamp = int(headers.get("X-Lrail-Timestamp", ""))
            request_id = headers.get("X-Lrail-Request-Id", "")
            UUID(request_id)
        except (TypeError, ValueError):
            return False
        now = int(time.time()) if now is None else now
        if abs(now - timestamp) > self.MAX_CLOCK_SKEW_SECONDS:
            return False
        signature = headers.get("X-Lrail-Signature", "")
        if not signature.startswith("sha256=") or len(signature) != 71:
            return False
        expected = self.headers(
            method=method,
            path=path,
            body=body,
            request_id=request_id,
            timestamp=timestamp,
        )["X-Lrail-Signature"]
        return hmac.compare_digest(signature, expected)
