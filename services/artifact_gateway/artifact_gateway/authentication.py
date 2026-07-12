from __future__ import annotations

import hashlib
import hmac
from pathlib import Path
import threading
import time
from typing import Mapping
from uuid import UUID


class RequestAuthenticator:
    MAX_CLOCK_SKEW_SECONDS = 60

    def __init__(self, secret_path: Path):
        secret = secret_path.read_bytes().strip()
        if not 32 <= len(secret) <= 4096:
            raise ValueError("artifact gateway admin secret is invalid")
        self._secret = secret
        self._seen: dict[str, int] = {}
        self._lock = threading.Lock()

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
        current = int(time.time()) if now is None else now
        if abs(current - timestamp) > self.MAX_CLOCK_SKEW_SECONDS:
            return False
        signature = headers.get("X-Lrail-Signature", "")
        if not signature.startswith("sha256=") or len(signature) != 71:
            return False
        message = b"\n".join(
            [
                str(timestamp).encode(),
                request_id.encode(),
                method.upper().encode(),
                path.encode(),
                body,
            ]
        )
        expected = f"sha256={hmac.new(self._secret, message, hashlib.sha256).hexdigest()}"
        if not hmac.compare_digest(signature, expected):
            return False
        with self._lock:
            self._seen = {
                value: seen_at
                for value, seen_at in self._seen.items()
                if current - seen_at <= self.MAX_CLOCK_SKEW_SECONDS
            }
            if request_id in self._seen:
                return False
            self._seen[request_id] = current
        return True
