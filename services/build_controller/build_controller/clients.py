from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import time
from typing import Any
from urllib.parse import quote, urlsplit
from uuid import uuid4

import aiohttp

from .contracts import CloneCredentials
from .store import Operation


class DependencyError(RuntimeError):
    def __init__(self, code: str, *, retryable: bool = True):
        super().__init__(code)
        self.code = code
        self.retryable = retryable


class SignedClient:
    def __init__(
        self,
        base_url: str,
        secret_path: Path,
        *,
        host_header: str | None = None,
    ):
        self._base_url = base_url.rstrip("/")
        self._secret = secret_path.read_bytes().strip()
        if not 32 <= len(self._secret) <= 4096:
            raise ValueError("dependency secret is invalid")
        self._host_header = host_header
        self._session: aiohttp.ClientSession | None = None

    async def close(self) -> None:
        if self._session is not None:
            await self._session.close()
            self._session = None

    async def request(
        self,
        method: str,
        path: str,
        *,
        body: bytes = b"",
        content_type: str = "application/json",
        expected: set[int] | None = None,
        extra_headers: dict[str, str] | None = None,
        params: dict[str, str] | None = None,
        timeout_seconds: int = 30,
    ) -> tuple[int, bytes]:
        timestamp = str(int(time.time()))
        request_id = str(uuid4())
        message = b"\n".join(
            [
                timestamp.encode(),
                request_id.encode(),
                method.upper().encode(),
                path.encode(),
                body,
            ]
        )
        signature = hmac.new(self._secret, message, hashlib.sha256).hexdigest()
        headers = {
            "Content-Type": content_type,
            "X-Lrail-Timestamp": timestamp,
            "X-Lrail-Request-Id": request_id,
            "X-Lrail-Signature": f"sha256={signature}",
        }
        if self._host_header:
            headers["Host"] = self._host_header
        headers.update(extra_headers or {})
        if self._session is None:
            self._session = aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=30, connect=5),
                trust_env=False,
            )
        try:
            async with self._session.request(
                method,
                self._base_url + path,
                data=body,
                headers=headers,
                params=params,
                timeout=aiohttp.ClientTimeout(total=timeout_seconds, connect=5),
            ) as response:
                value = await response.read()
                allowed = expected or set(range(200, 300))
                if response.status not in allowed:
                    retryable = response.status >= 500 or response.status in {
                        408,
                        409,
                        425,
                        429,
                    }
                    raise DependencyError(
                        f"dependency_{response.status}", retryable=retryable
                    )
                return response.status, value
        except (aiohttp.ClientError, TimeoutError) as error:
            raise DependencyError("dependency_unavailable") from error

    async def json(
        self,
        method: str,
        path: str,
        value: dict[str, object],
        *,
        expected: set[int] | None = None,
        timeout_seconds: int = 30,
    ) -> tuple[int, dict[str, Any]]:
        body = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
        status, response = await self.request(
            method,
            path,
            body=body,
            expected=expected,
            timeout_seconds=timeout_seconds,
        )
        try:
            parsed = json.loads(response)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise DependencyError(
                "dependency_response_invalid", retryable=False
            ) from error
        if not isinstance(parsed, dict):
            raise DependencyError("dependency_response_invalid", retryable=False)
        return status, parsed


@dataclass(frozen=True)
class CommandLease:
    event: dict[str, Any]
    claim_token: str


class ControlPlaneClient:
    EVENT_TYPES = ["build.requested.v1", "build.cancellation.requested.v1"]

    def __init__(
        self,
        base_url: str,
        secret_path: Path,
        *,
        host_header: str | None = None,
    ):
        self._client = SignedClient(base_url, secret_path, host_header=host_header)

    async def close(self) -> None:
        await self._client.close()

    async def claim(self) -> CommandLease | None:
        path = "/internal/v1/build-controller/commands/claim"
        body = json.dumps(
            {"event_types": self.EVENT_TYPES}, separators=(",", ":"), sort_keys=True
        ).encode()
        status, response = await self._client.request(
            "POST", path, body=body, expected={200, 204}
        )
        if status == 204:
            return None
        try:
            value = json.loads(response)
            event = value["event"]
            claim_token = str(value["claim_token"])
        except (KeyError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise DependencyError("command_response_invalid", retryable=False) from error
        if not isinstance(event, dict):
            raise DependencyError("command_response_invalid", retryable=False)
        return CommandLease(event=event, claim_token=claim_token)

    async def finalize(
        self,
        *,
        event_id: str,
        claim_token: str,
        outcome: str,
        safe_error: str | None = None,
    ) -> dict[str, Any]:
        value: dict[str, object] = {"claim_token": claim_token, "outcome": outcome}
        if safe_error:
            value["safe_error"] = safe_error[:500]
        _status, response = await self._client.json(
            "POST",
            f"/internal/v1/build-controller/commands/{event_id}/finalize",
            value,
        )
        return response

    async def credentials(self, operation: Operation) -> CloneCredentials:
        path = f"/internal/v1/build-controller/builds/{operation.build_id}/credentials"
        status, body = await self._client.request(
            "GET",
            path,
            params={"operation_id": operation.operation_id},
            expected={200},
        )
        del status
        try:
            value = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise DependencyError("credential_response_invalid", retryable=False) from error
        credentials = CloneCredentials.parse(value, build_id=operation.build_id)
        raw_url = credentials.clone_url
        parsed = urlsplit(raw_url)
        if (
            parsed.query
            or parsed.fragment
            or any(ord(character) < 32 or ord(character) == 127 for character in raw_url)
        ):
            raise DependencyError("credential_response_invalid", retryable=False)
        return credentials

    async def send_build_event(
        self,
        operation: Operation,
        *,
        status: str,
        evidence: dict[str, Any] | None = None,
        artifact_digest: str | None = None,
        failure: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        event_id = str(uuid4())
        data: dict[str, Any] = {
            "contract_version": 1,
            "operation_id": operation.operation_id,
            "deployment_id": operation.deployment_id,
            "build_id": operation.build_id,
            "expected_version": operation.expected_version,
            "status": status,
        }
        if status == "completed":
            data.update(
                revision_id=operation.revision_id,
                artifact_digest=artifact_digest,
                evidence=evidence,
                region="local",
                cell="lrail-alpha",
            )
        else:
            if failure is None:
                raise ValueError("build failure is missing")
            data.update(
                failure_code=failure["code"],
                error=failure,
                evidence=evidence or {},
            )
        envelope = {
            "event_id": event_id,
            "event_type": "deployment.build.completed.v1",
            "occurred_at": datetime.now(timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "organization_id": operation.organization_id,
            "resource_id": operation.deployment_id,
            "correlation_id": operation.correlation_id,
            "idempotency_key": f"build:{operation.build_id}:{status}",
            "producer": "build-controller",
            "schema_version": 1,
            "data": data,
        }
        _status, response = await self._client.json(
            "POST", "/internal/v1/build-controller/events", envelope
        )
        return response

    async def complete_cancellation(
        self,
        operation: Operation,
        *,
        operation_id: str,
        expected_version: int,
        evidence: dict[str, Any],
    ) -> dict[str, Any]:
        value = {
            "contract_version": 1,
            "operation_id": operation_id,
            "organization_id": operation.organization_id,
            "deployment_id": operation.deployment_id,
            "build_id": operation.build_id,
            "expected_version": expected_version,
            "evidence": evidence,
        }
        _status, response = await self._client.json(
            "POST", "/internal/v1/build-controller/cancellations", value
        )
        return response


@dataclass(frozen=True, repr=False)
class RegistryCredential:
    credential_id: str
    username: str
    password: str
    repository: str
    expires_at: int

    def __repr__(self) -> str:
        return (
            f"RegistryCredential(credential_id={self.credential_id!r}, "
            f"username={self.username!r}, password=[REDACTED], "
            f"repository={self.repository!r}, expires_at={self.expires_at})"
        )


class RegistryAuthClient:
    def __init__(self, base_url: str, secret_path: Path):
        self._client = SignedClient(base_url, secret_path)

    async def close(self) -> None:
        await self._client.close()

    async def register(
        self,
        *,
        repository: str,
        actions: list[str],
        expires_at: int,
    ) -> RegistryCredential:
        credential_id = str(uuid4())
        username = "lr_" + secrets.token_hex(12)
        password = secrets.token_urlsafe(48)
        value = {
            "credential_id": credential_id,
            "username": username,
            "password": password,
            "repository_prefix": repository,
            "actions": actions,
            "expires_at": expires_at,
        }
        await self._client.json("POST", "/v1/credentials", value, expected={201})
        return RegistryCredential(
            credential_id=credential_id,
            username=username,
            password=password,
            repository=repository,
            expires_at=expires_at,
        )

    async def revoke(self, credential_id: str) -> None:
        try:
            await self._client.request(
                "DELETE", f"/v1/credentials/{credential_id}", expected={200, 404}
            )
        except DependencyError as error:
            if not error.retryable:
                return
            raise


class ArtifactGatewayClient:
    def __init__(self, base_url: str, secret_path: Path):
        self._client = SignedClient(base_url, secret_path)

    async def close(self) -> None:
        await self._client.close()

    async def evidence(
        self,
        *,
        organization_id: str,
        build_id: str,
        name: str,
        body: bytes,
    ) -> dict[str, Any]:
        path = f"/v1/evidence/{organization_id}/{build_id}/{quote(name, safe='')}"
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        _status, response = await self._client.request(
            "PUT",
            path,
            body=body,
            content_type="application/json" if name.endswith(".json") else "text/plain",
            expected={200, 201},
            extra_headers={"X-Lrail-Artifact-Digest": digest},
            timeout_seconds=60,
        )
        try:
            value = json.loads(response)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise DependencyError("artifact_response_invalid", retryable=False) from error
        if not isinstance(value, dict) or value.get("digest") != digest:
            raise DependencyError("artifact_response_invalid", retryable=False)
        return value

    async def static(
        self,
        *,
        organization_id: str,
        revision_id: str,
        archive: bytes,
    ) -> dict[str, Any]:
        path = f"/v1/static/{organization_id}/{revision_id}"
        digest = "sha256:" + hashlib.sha256(archive).hexdigest()
        _status, response = await self._client.request(
            "PUT",
            path,
            body=archive,
            content_type="application/x-tar",
            expected={200, 201},
            extra_headers={"X-Lrail-Artifact-Digest": digest},
            timeout_seconds=120,
        )
        try:
            value = json.loads(response)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise DependencyError("artifact_response_invalid", retryable=False) from error
        if (
            not isinstance(value, dict)
            or value.get("archive", {}).get("digest") != digest
        ):
            raise DependencyError("artifact_response_invalid", retryable=False)
        return value
