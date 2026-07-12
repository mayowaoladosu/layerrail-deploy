from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import json
import re
from typing import Any
from uuid import UUID


_EVENT_TYPE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\.v[1-9][0-9]*$")
_PRODUCER = re.compile(r"^[a-z][a-z0-9-]*$")
_REQUIRED_KEYS = {
    "event_id",
    "event_type",
    "occurred_at",
    "organization_id",
    "resource_id",
    "correlation_id",
    "idempotency_key",
    "producer",
    "schema_version",
    "data",
}


class InvalidEnvelope(ValueError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


@dataclass(frozen=True)
class Envelope:
    value: dict[str, Any]

    @classmethod
    def parse(cls, value: Any) -> "Envelope":
        if not isinstance(value, dict) or set(value) != _REQUIRED_KEYS:
            raise InvalidEnvelope("event envelope keys are invalid")
        for key in ("event_id", "organization_id", "resource_id", "correlation_id"):
            try:
                UUID(str(value[key]))
            except (ValueError, TypeError) as error:
                raise InvalidEnvelope(f"{key} is invalid") from error
        try:
            datetime.fromisoformat(str(value["occurred_at"]).replace("Z", "+00:00"))
        except ValueError as error:
            raise InvalidEnvelope("occurred_at is invalid") from error
        if not _EVENT_TYPE.fullmatch(str(value["event_type"])):
            raise InvalidEnvelope("event_type is invalid")
        if not _PRODUCER.fullmatch(str(value["producer"])):
            raise InvalidEnvelope("producer is invalid")
        key = value["idempotency_key"]
        if not isinstance(key, str) or not key or key != key.strip() or len(key) > 255:
            raise InvalidEnvelope("idempotency_key is invalid")
        if value["schema_version"] != 1:
            raise InvalidEnvelope("schema_version is unsupported")
        if not isinstance(value["data"], dict):
            raise InvalidEnvelope("data must be an object")
        if len(canonical_json(value["data"])) > 64 * 1024:
            raise InvalidEnvelope("data is too large")
        return cls(value=json.loads(canonical_json(value)))

    @property
    def event_id(self) -> str:
        return self.value["event_id"]

    @property
    def event_type(self) -> str:
        return self.value["event_type"]

    @property
    def data(self) -> dict[str, Any]:
        return self.value["data"]
