from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import uuid4

import httpx

from .authentication import RequestSigner
from .contracts import Envelope, canonical_json


class ControlPlaneUnavailable(RuntimeError):
    pass


class ControlPlaneRejected(RuntimeError):
    pass


@dataclass(frozen=True)
class Command:
    envelope: Envelope
    claim_token: str
    lease_expires_at: str


class ControlPlaneClient:
    EVENT_TYPES = [
        "deployment.requested.v1",
        "deployment.cancellation.requested.v1",
        "alias.routing.requested.v1",
    ]

    def __init__(
        self,
        *,
        base_url: str,
        signer: RequestSigner,
        host_header: str | None = None,
        client: httpx.AsyncClient | None = None,
    ):
        self._signer = signer
        self._client = client or httpx.AsyncClient(
            base_url=base_url,
            headers={"Host": host_header} if host_header else None,
            timeout=httpx.Timeout(10.0, connect=5.0),
            trust_env=False,
        )
        self._owns_client = client is None

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def claim(self) -> Command | None:
        path = "/internal/v1/local-provider/commands/claim"
        payload = {"event_types": self.EVENT_TYPES}
        response = await self._post(path, payload)
        if response.status_code == 204:
            return None
        self._ensure_success(response)
        value = response.json()
        return Command(
            envelope=Envelope.parse(value["event"]),
            claim_token=str(value["claim_token"]),
            lease_expires_at=str(value["lease_expires_at"]),
        )

    async def finalize(
        self,
        *,
        event_id: str,
        claim_token: str,
        outcome: str,
        safe_error: str | None = None,
    ) -> dict[str, Any]:
        path = f"/internal/v1/local-provider/commands/{event_id}/finalize"
        payload: dict[str, Any] = {
            "claim_token": claim_token,
            "outcome": outcome,
        }
        if safe_error:
            payload["safe_error"] = safe_error[:1000]
        response = await self._post(path, payload)
        self._ensure_success(response)
        return response.json()

    async def callback(self, envelope: dict[str, Any]) -> dict[str, Any]:
        path = "/internal/v1/local-provider/events"
        response = await self._post(path, envelope)
        self._ensure_success(response)
        return response.json()

    async def health(self) -> bool:
        try:
            response = await self._client.get("/health")
            return response.status_code == 200
        except httpx.HTTPError:
            return False

    async def _post(self, path: str, payload: dict[str, Any]) -> httpx.Response:
        body = canonical_json(payload)
        request_id = str(uuid4())
        headers = self._signer.headers(
            method="POST",
            path=path,
            body=body,
            request_id=request_id,
        )
        try:
            return await self._client.post(path, content=body, headers=headers)
        except httpx.HTTPError as error:
            raise ControlPlaneUnavailable("control plane request failed") from error

    def _ensure_success(self, response: httpx.Response) -> None:
        if response.status_code >= 500:
            raise ControlPlaneUnavailable(
                f"control plane returned HTTP {response.status_code}"
            )
        if response.status_code >= 400:
            raise ControlPlaneRejected(
                f"control plane rejected request with HTTP {response.status_code}"
            )
