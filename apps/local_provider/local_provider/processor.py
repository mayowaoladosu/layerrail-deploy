from __future__ import annotations

from datetime import datetime, timezone
import logging
import re
from typing import Any
from uuid import NAMESPACE_URL, uuid5

from .contracts import Envelope
from .control_plane import ControlPlaneClient, ControlPlaneUnavailable
from .routing import InvalidRoute, RouteWriter
from .runtime import (
    DockerRuntime,
    ReadinessFailed,
    RuntimeConflict,
    RuntimeUnavailable,
)
from .state import EventConflict, StateStore


logger = logging.getLogger(__name__)


class PermanentCommandError(RuntimeError):
    pass


class TransientCommandError(RuntimeError):
    pass


class Processor:
    def __init__(
        self,
        *,
        store: StateStore,
        runtime: DockerRuntime,
        routes: RouteWriter,
        control_plane: ControlPlaneClient,
        allowed_image_reference: str = "lrail-local-sample:dev",
    ):
        self._store = store
        self._runtime = runtime
        self._routes = routes
        self._control_plane = control_plane
        self._allowed_image_reference = allowed_image_reference

    async def process(self, envelope: Envelope) -> dict[str, Any]:
        try:
            status, result = self._store.receive(envelope.event_id, envelope.value)
        except EventConflict as error:
            raise PermanentCommandError("Command conflicts with its receipt") from error
        if status == "completed":
            await self._replay_callback(result)
            return result

        try:
            if envelope.event_type == "deployment.requested.v1":
                result = await self._deployment(envelope)
            elif envelope.event_type == "deployment.cancellation.requested.v1":
                result = await self._cancellation(envelope)
            elif envelope.event_type == "alias.routing.requested.v1":
                result = self._alias(envelope)
            else:
                raise PermanentCommandError("Command type is unsupported")
        except ControlPlaneUnavailable as error:
            raise TransientCommandError("Control plane callback unavailable") from error
        except RuntimeUnavailable as error:
            raise TransientCommandError("Local Docker runtime unavailable") from error

        self._store.complete(envelope.event_id, result)
        return result

    async def _deployment(self, envelope: Envelope) -> dict[str, Any]:
        data = envelope.data
        source = data.get("source")
        if not isinstance(source, dict) or source.get("type") != "oci":
            return await self._fail(
                envelope,
                code="git_build_unavailable",
                message="Git builds require the isolated build provider",
            )
        if source.get("reference") != self._allowed_image_reference:
            return await self._fail(
                envelope,
                code="oci_image_not_allowed",
                message="Local provider accepts only the repository sample image",
            )
        if data.get("configuration_present") is not False:
            return await self._fail(
                envelope,
                code="runtime_configuration_unavailable",
                message="Local provider configuration injection is not available",
            )
        if data.get("workload_type") != "web":
            return await self._fail(
                envelope,
                code="workload_type_unsupported",
                message="Local provider supports web samples only",
            )
        digest = source.get("digest")
        if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise PermanentCommandError("OCI artifact digest is invalid")
        readiness_path = data.get("runtime_policy", {}).get("readiness_path", "/health")
        if not isinstance(readiness_path, str) or not readiness_path.startswith("/"):
            raise PermanentCommandError("Readiness path is invalid")

        try:
            instance = await self._runtime.ensure(
                deployment_id=str(data["deployment_id"]),
                organization_id=str(envelope.value["organization_id"]),
                source=source,
                source_digest=str(digest),
                immutable_hostname=str(data["immutable_hostname"]),
                readiness_path=readiness_path,
            )
        except ReadinessFailed as error:
            await self._runtime.remove(
                deployment_id=str(data["deployment_id"]),
                organization_id=str(envelope.value["organization_id"]),
            )
            logger.warning(
                "Local runtime rejected deployment %s: %s",
                data.get("deployment_id"),
                type(error).__name__,
            )
            return await self._fail(
                envelope,
                code="runtime_failed",
                message="Local runtime could not start the deployment",
            )
        except RuntimeConflict as error:
            logger.warning(
                "Local runtime rejected deployment %s: %s",
                data.get("deployment_id"),
                type(error).__name__,
            )
            return await self._fail(
                envelope,
                code="runtime_failed",
                message="Local runtime could not start the deployment",
            )

        callback = self._callback_envelope(
            envelope,
            event_type="deployment.runtime.ready.v1",
            data={
                "deployment_id": data["deployment_id"],
                "operation_id": envelope.event_id,
                "expected_version": data["expected_version"],
                "artifact_digest": digest,
                "region": "local",
                "cell": "docker-desktop",
                "readiness": {
                    "status": "passed",
                    "checked_at": self._now(),
                },
            },
        )
        callback_response = await self._control_plane.callback(callback)
        revision_id = callback_response["result"]["revision_id"]
        if not revision_id:
            raise PermanentCommandError("Ready callback did not create a Revision")
        self._store.save_revision(
            revision_id=str(revision_id),
            deployment_id=str(data["deployment_id"]),
            container_id=instance.container_id,
            container_name=instance.container_name,
            container_port=instance.container_port,
        )
        return {
            "kind": "deployment_ready",
            "deployment_id": str(data["deployment_id"]),
            "revision_id": str(revision_id),
            "container_id": instance.container_id,
            "container_name": instance.container_name,
            "callback": callback,
        }

    async def _fail(
        self, envelope: Envelope, *, code: str, message: str
    ) -> dict[str, Any]:
        callback = self._callback_envelope(
            envelope,
            event_type="deployment.runtime.failed.v1",
            data={
                "deployment_id": envelope.data["deployment_id"],
                "operation_id": envelope.event_id,
                "expected_version": envelope.data["expected_version"],
                "phase": "runtime",
                "code": code,
                "message": message,
                "diagnostic_reference": f"local-provider:{envelope.event_id}",
            },
        )
        await self._control_plane.callback(callback)
        return {
            "kind": "deployment_failed",
            "deployment_id": str(envelope.data["deployment_id"]),
            "code": code,
            "callback": callback,
        }

    async def _cancellation(self, envelope: Envelope) -> dict[str, Any]:
        data = envelope.data
        deployment_id = str(data.get("deployment_id", ""))
        if not deployment_id:
            raise PermanentCommandError("Cancellation command is incomplete")
        await self._runtime.remove(
            deployment_id=deployment_id,
            organization_id=str(envelope.value["organization_id"]),
        )
        self._routes.remove_deployment(deployment_id)
        callback = self._callback_envelope(
            envelope,
            event_type="deployment.runtime.canceled.v1",
            data={
                "deployment_id": deployment_id,
                "operation_id": envelope.event_id,
                "expected_version": data["expected_version"],
            },
        )
        await self._control_plane.callback(callback)
        return {
            "kind": "deployment_canceled",
            "deployment_id": deployment_id,
            "callback": callback,
        }

    def _alias(self, envelope: Envelope) -> dict[str, Any]:
        try:
            result = self._routes.apply(envelope.data)
        except InvalidRoute as error:
            raise TransientCommandError("Alias target is not ready locally") from error
        return {"kind": "alias_routed", **result}

    async def _replay_callback(self, result: dict[str, Any]) -> None:
        callback = result.get("callback") if isinstance(result, dict) else None
        if callback:
            await self._control_plane.callback(callback)

    def _callback_envelope(
        self,
        command: Envelope,
        *,
        event_type: str,
        data: dict[str, Any],
    ) -> dict[str, Any]:
        suffix = event_type.removeprefix("deployment.runtime.").removesuffix(".v1")
        event_id = str(
            uuid5(
                NAMESPACE_URL,
                f"https://events.layerrail.local/{command.event_id}/{suffix}",
            )
        )
        return {
            "event_id": event_id,
            "event_type": event_type,
            "occurred_at": self._now(),
            "organization_id": command.value["organization_id"],
            "resource_id": command.value["resource_id"],
            "correlation_id": command.value["correlation_id"],
            "idempotency_key": f"local-provider:{command.event_id}:{suffix}",
            "producer": "local-provider",
            "schema_version": 1,
            "data": data,
        }

    def _now(self) -> str:
        return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
            "+00:00", "Z"
        )
