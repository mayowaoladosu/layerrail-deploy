from __future__ import annotations

from datetime import datetime
import re
from typing import Iterable


class RuntimeLogFormatter:
    MAX_SOURCE_LINES = 1000
    MAX_ENTRIES = 200
    MAX_MESSAGE_LENGTH = 4096

    def format(self, lines: Iterable[str]) -> tuple[list[dict[str, str]], bool]:
        source = [str(line) for line in lines][-self.MAX_SOURCE_LINES :]
        visible = [entry for line in source if (entry := self._entry(line))]
        return visible[-self.MAX_ENTRIES :], (
            len(visible) > self.MAX_ENTRIES or len(source) >= self.MAX_SOURCE_LINES
        )

    def _entry(self, line: str) -> dict[str, str] | None:
        timestamp, separator, message = line.partition(" ")
        if not separator:
            return None
        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError:
            return None
        message = self._redact(message.rstrip("\r\n\x00"))[: self.MAX_MESSAGE_LENGTH]
        if not message:
            return None
        if message.startswith('sample-web 127.0.0.1 "GET /health '):
            return None
        return {
            "timestamp": timestamp,
            "stream": "runtime",
            "message": message,
        }

    def _redact(self, message: str) -> str:
        message = re.sub(
            r"(?i)(authorization\s*:\s*)([^\s]+(?:\s+[^\s]+)?)",
            r"\1[REDACTED]",
            message,
        )
        return re.sub(
            r"(?i)((?:token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s&]+",
            r"\1[REDACTED]",
            message,
        )
