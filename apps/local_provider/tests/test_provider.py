from __future__ import annotations

import asyncio
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

import yaml

from local_provider.authentication import RequestSigner
from local_provider.contracts import Envelope, InvalidEnvelope
from local_provider.logs import RuntimeLogFormatter
from local_provider.processor import Processor
from local_provider.routing import RouteWriter
from local_provider.runtime import (
    DockerRuntime,
    ReadinessFailed,
    RuntimeConflict,
    RuntimeInstance,
)
from local_provider.state import EventConflict, StateStore


def event(event_type: str, data: dict) -> dict:
    return {
        "event_id": str(uuid4()),
        "event_type": event_type,
        "occurred_at": "2026-07-12T00:00:00Z",
        "organization_id": str(uuid4()),
        "resource_id": str(uuid4()),
        "correlation_id": str(uuid4()),
        "idempotency_key": f"test:{uuid4()}",
        "producer": "control-plane",
        "schema_version": 1,
        "data": data,
    }


class FakeRuntime:
    def __init__(self):
        self.calls = 0
        self.removals: list[str] = []
        self.ensure_error: Exception | None = None

    async def ensure(self, **_kwargs):
        self.calls += 1
        if self.ensure_error:
            raise self.ensure_error
        return RuntimeInstance(
            container_id="container-1",
            container_name="lrail-runtime-deployment",
            container_port=8000,
        )

    async def remove(self, *, deployment_id, organization_id):
        organization_id
        self.removals.append(deployment_id)

    async def logs(self, *, deployment_id, organization_id, limit=200):
        deployment_id, organization_id, limit
        return ["2026-07-12T00:00:00Z sample runtime line\n"]

    def resource_profile(self):
        return {"cpu_millicores": 500, "memory_bytes": 268435456}


class FakeControlPlane:
    def __init__(self):
        self.callbacks: list[dict] = []

    async def callback(self, envelope):
        self.callbacks.append(envelope)
        if envelope["event_type"] == "deployment.runtime.ready.v1":
            return {
                "result": {
                    "deployment_id": envelope["resource_id"],
                    "revision_id": "revision-1",
                    "ignored": False,
                },
                "replayed": len(self.callbacks) > 1,
            }
        return {
            "result": {
                "deployment_id": envelope["resource_id"],
                "revision_id": None,
                "ignored": False,
            },
            "replayed": False,
        }


class ContractTests(unittest.TestCase):
    def test_envelope_rejects_unknown_fields(self):
        value = event("deployment.requested.v1", {"expected_version": 0})
        value["secret"] = "not allowed"
        with self.assertRaises(InvalidEnvelope):
            Envelope.parse(value)

    def test_request_signature_is_stable_and_body_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            secret = Path(directory) / "secret"
            secret.write_text("x" * 32)
            signer = RequestSigner(secret)
            first = signer.headers(
                method="POST",
                path="/commands",
                body=b"{}",
                request_id="00000000-0000-4000-8000-000000000001",
                timestamp=100,
            )
            second = signer.headers(
                method="POST",
                path="/commands",
                body=b'{"changed":true}',
                request_id="00000000-0000-4000-8000-000000000001",
                timestamp=100,
            )
            self.assertNotEqual(first["X-Lrail-Signature"], second["X-Lrail-Signature"])
            self.assertTrue(
                signer.valid(
                    method="POST",
                    path="/commands",
                    body=b"{}",
                    headers=first,
                    now=100,
                )
            )
            self.assertFalse(
                signer.valid(
                    method="POST",
                    path="/commands",
                    body=b'{"changed":true}',
                    headers=first,
                    now=100,
                )
            )
            self.assertFalse(
                signer.valid(
                    method="POST",
                    path="/commands",
                    body=b"{}",
                    headers=first,
                    now=161,
                )
            )

    def test_runtime_log_entries_are_timestamped_bounded_and_redacted(self):
        formatter = RuntimeLogFormatter()

        entries, truncated = formatter.format(
            [
                "2026-07-12T00:00:00.123456789Z authorization: Bearer private "
                "token=also-private request completed\n"
            ]
        )
        entry = entries[0]

        self.assertFalse(truncated)
        self.assertEqual(entry["timestamp"], "2026-07-12T00:00:00.123456789Z")
        self.assertEqual(entry["stream"], "runtime")
        self.assertEqual(
            entry["message"],
            "authorization: [REDACTED] token=[REDACTED] request completed",
        )
        entries, _truncated = formatter.format(
            [
                "not-timestamped",
                '2026-07-12T00:00:00Z sample-web 127.0.0.1 "GET /health HTTP/1.1" 200 -\n'
            ]
        )
        self.assertEqual(entries, [])


class StateTests(unittest.TestCase):
    def test_receipt_is_idempotent_and_detects_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            store = StateStore(Path(directory) / "state.sqlite3")
            value = event("deployment.requested.v1", {"expected_version": 0})
            self.assertEqual(store.receive(value["event_id"], value), ("processing", None))
            store.complete(value["event_id"], {"ok": True})
            self.assertEqual(
                store.receive(value["event_id"], value),
                ("completed", {"ok": True}),
            )
            value["data"]["expected_version"] = 1
            with self.assertRaises(EventConflict):
                store.receive(value["event_id"], value)
            store.save_runtime_logs(
                deployment_id="deployment-1",
                organization_id="organization-1",
                entries=[
                    {
                        "timestamp": "2026-07-12T00:00:00Z",
                        "stream": "runtime",
                        "message": "redacted output",
                    }
                ],
                truncated=False,
            )
            self.assertEqual(
                store.runtime_logs(
                    deployment_id="deployment-1",
                    organization_id="organization-1",
                )["entries"][0]["message"],
                "redacted output",
            )
            with self.assertRaises(EventConflict):
                store.save_runtime_logs(
                    deployment_id="deployment-1",
                    organization_id="foreign-organization",
                    entries=[],
                    truncated=False,
                )
            store.close()


class ProcessorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.store = StateStore(root / "state.sqlite3")
        self.runtime = FakeRuntime()
        self.control_plane = FakeControlPlane()
        self.routes = RouteWriter(
            store=self.store,
            routes_dir=root / "routes",
            deploy_domain="localhost",
        )
        self.processor = Processor(
            store=self.store,
            runtime=self.runtime,
            routes=self.routes,
            control_plane=self.control_plane,
        )

    async def asyncTearDown(self):
        self.store.close()
        self.directory.cleanup()

    def deployment_event(self, source_type: str = "oci") -> Envelope:
        deployment_id = str(uuid4())
        digest = "sha256:" + "a" * 64
        source = (
            {"type": "oci", "reference": "lrail-local-sample:dev", "digest": digest}
            if source_type == "oci"
            else {
                "type": "git",
                "reference": "main",
                "repository_id": "repo-1",
                "commit_sha": "a" * 40,
            }
        )
        return Envelope.parse(
            event(
                "deployment.requested.v1",
                {
                    "deployment_id": deployment_id,
                    "expected_version": 0,
                    "source": source,
                    "source_digest": digest,
                    "runtime_policy": {"readiness_path": "/health"},
                    "workload_type": "web",
                    "configuration_present": False,
                    "immutable_hostname": f"d-{deployment_id}.localhost",
                    "container_port": 8000,
                },
            )
        )

    async def test_oci_deployment_calls_back_once_and_replays_safely(self):
        command = self.deployment_event()
        first = await self.processor.process(command)
        second = await self.processor.process(command)

        self.assertEqual(first["revision_id"], "revision-1")
        self.assertEqual(second, first)
        self.assertEqual(self.runtime.calls, 1)
        self.assertEqual(len(self.control_plane.callbacks), 2)
        self.assertEqual(
            self.control_plane.callbacks[0]["event_id"],
            self.control_plane.callbacks[1]["event_id"],
        )
        self.assertEqual(
            self.control_plane.callbacks[0]["data"]["readiness"]["resources"],
            {"cpu_millicores": 500, "memory_bytes": 268435456},
        )
        revision = self.store.revision_for_deployment(command.data["deployment_id"])
        self.assertEqual(revision["revision_id"], "revision-1")

    async def test_git_command_reports_a_safe_failure_without_runtime_execution(self):
        command = self.deployment_event(source_type="git")

        result = await self.processor.process(command)

        self.assertEqual(result["kind"], "deployment_failed")
        self.assertEqual(result["code"], "git_build_unavailable")
        self.assertEqual(self.runtime.calls, 0)
        self.assertEqual(
            self.control_plane.callbacks[0]["event_type"],
            "deployment.runtime.failed.v1",
        )

    async def test_untrusted_oci_reference_reports_failure_without_execution(self):
        command = self.deployment_event()
        command.value["data"]["source"]["reference"] = "untrusted/image:latest"

        result = await self.processor.process(command)

        self.assertEqual(result["code"], "oci_image_not_allowed")
        self.assertEqual(self.runtime.calls, 0)

    async def test_readiness_failure_removes_the_candidate_before_callback(self):
        command = self.deployment_event()
        self.runtime.ensure_error = ReadinessFailed("not ready")

        result = await self.processor.process(command)

        self.assertEqual(result["code"], "runtime_failed")
        self.assertEqual(self.runtime.removals, [command.data["deployment_id"]])
        self.assertEqual(
            self.control_plane.callbacks[-1]["event_type"],
            "deployment.runtime.failed.v1",
        )

    async def test_alias_routing_targets_the_ready_local_revision(self):
        deployment = self.deployment_event()
        await self.processor.process(deployment)
        alias = Envelope.parse(
            event(
                "alias.routing.requested.v1",
                {
                    "alias_id": str(uuid4()),
                    "hostname": "sample-web-production.localhost",
                    "current_revision_id": "revision-1",
                    "previous_revision_id": None,
                    "current_deployment_id": deployment.data["deployment_id"],
                    "container_port": 8000,
                    "expected_version": 1,
                },
            )
        )

        result = await self.processor.process(alias)
        route_file = Path(self.directory.name) / "routes" / "lrail-local-provider.yml"
        rendered = yaml.safe_load(route_file.read_text())

        self.assertEqual(result["kind"], "alias_routed")
        routers = rendered["http"]["routers"]
        self.assertEqual(len(routers), 1)
        self.assertIn("sample-web-production.localhost", next(iter(routers.values()))["rule"])

    async def test_cancellation_removes_the_managed_runtime_and_calls_back(self):
        deployment = self.deployment_event()
        await self.processor.process(deployment)
        cancellation_value = event(
            "deployment.cancellation.requested.v1",
            {
                "deployment_id": deployment.data["deployment_id"],
                "expected_version": 8,
            },
        )
        for key in ("organization_id", "resource_id", "correlation_id"):
            cancellation_value[key] = deployment.value[key]
        cancellation = Envelope.parse(cancellation_value)

        result = await self.processor.process(cancellation)

        self.assertEqual(result["kind"], "deployment_canceled")
        self.assertEqual(self.runtime.removals, [deployment.data["deployment_id"]])
        self.assertEqual(
            self.control_plane.callbacks[-1]["event_type"],
            "deployment.runtime.canceled.v1",
        )
        retained = self.store.runtime_logs(
            deployment_id=deployment.data["deployment_id"],
            organization_id=deployment.value["organization_id"],
        )
        self.assertEqual(retained["entries"][0]["message"], "sample runtime line")


class RuntimeConfigurationTests(unittest.TestCase):
    def test_runtime_health_and_security_are_part_of_container_creation(self):
        runtime = DockerRuntime(
            docker=None,
            runtime_network="devpush_local_runtime",
            container_port=8000,
        )
        config = runtime._container_config(
            image="lrail-local-sample:dev",
            name="lrail-runtime-deployment",
            deployment_id="00000000-0000-4000-8000-000000000001",
            organization_id="00000000-0000-4000-8000-000000000002",
            source_digest="sha256:" + "a" * 64,
            immutable_hostname="d-00000000-0000-4000-8000-000000000001.localhost",
            readiness_path="/health",
        )

        self.assertEqual(config["User"], "10001:10001")
        self.assertEqual(config["Healthcheck"]["Test"][-1], "/health")
        self.assertEqual(config["HostConfig"]["CapDrop"], ["ALL"])
        self.assertTrue(config["HostConfig"]["ReadonlyRootfs"])
        self.assertEqual(
            config["HostConfig"]["SecurityOpt"], ["no-new-privileges:true"]
        )
        self.assertEqual(
            runtime.resource_profile(),
            {"cpu_millicores": 500, "memory_bytes": 268435456},
        )


class RuntimeLogTests(unittest.IsolatedAsyncioTestCase):
    class Container:
        def __init__(self):
            self.log_options = None

        async def show(self):
            return {
                "Config": {
                    "Labels": {
                        "com.layerrail.managed": "true",
                        "com.layerrail.deployment-id": "deployment-1",
                        "com.layerrail.organization-id": "organization-1",
                    }
                }
            }

        async def log(self, **options):
            self.log_options = options
            return ["2026-07-12T00:00:00Z sample ready\n"]

    class Containers:
        def __init__(self, container):
            self.container = container

        async def get(self, _name):
            return self.container

    class Docker:
        def __init__(self, container):
            self.containers = RuntimeLogTests.Containers(container)

    async def test_logs_are_bounded_and_require_matching_runtime_identity(self):
        container = self.Container()
        runtime = DockerRuntime(
            docker=self.Docker(container),
            runtime_network="devpush_local_runtime",
            container_port=8000,
        )

        lines = await runtime.logs(
            deployment_id="deployment-1",
            organization_id="organization-1",
            limit=500,
        )

        self.assertEqual(lines, ["2026-07-12T00:00:00Z sample ready\n"])
        self.assertEqual(
            container.log_options,
            {
                "stdout": True,
                "stderr": True,
                "timestamps": True,
                "tail": 500,
            },
        )
        with self.assertRaises(RuntimeConflict):
            await runtime.logs(
                deployment_id="deployment-1",
                organization_id="foreign-organization",
            )


if __name__ == "__main__":
    unittest.main()
