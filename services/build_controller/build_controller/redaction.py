from __future__ import annotations

import re


_PATTERNS = [
    re.compile(r"(?i)(authorization\s*[:=]\s*)(?:bearer|basic)?\s*[^\s,;]+"),
    re.compile(r"(?i)((?:password|passwd|token|secret|api[_-]?key)\s*[:=]\s*)[^\s,;]+"),
    re.compile(r"https://[^/@\s:]+:[^/@\s]+@"),
]


def redact(value: str, *, known: tuple[str, ...] = ()) -> str:
    result = value.replace("\r", " ").replace("\n", " ")
    for secret in known:
        if secret:
            result = result.replace(secret, "[REDACTED]")
    for pattern in _PATTERNS:
        if pattern.pattern.startswith("https"):
            result = pattern.sub("https://[REDACTED]@", result)
        else:
            result = pattern.sub(r"\1[REDACTED]", result)
    return result[:4096]


def redact_lines(
    values: tuple[str, ...] | list[str],
    *,
    known: tuple[str, ...] = (),
    limit: int = 200,
) -> list[str]:
    return [redact(value, known=known) for value in values[-limit:] if value]
