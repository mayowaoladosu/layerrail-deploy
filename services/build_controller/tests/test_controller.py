from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

from build_controller.authentication import RequestAuthenticator
from build_controller.clients import CommandLease, RegistryCredential
from build_controller.config import Settings
from build_controller.contracts import BuildCommand, CloneCredentials, WorkerResult
from build_controller.controller import BuildController
from build_controller.kubernetes import JobState
from build_controller.scanner import ScanResult
from build_controller.store import OperationConflict, OperationStore


COMMIT = "a" * 40


def envelope() -> dict[str, object]:
    organization_id = str(uuid4())
    service_id = str(uuid4())
    build_id = str(uuid4())
    return {
        "event_id": str(uuid4()),
        "event_type": "build.requested.v1",
        "occurred_at": "2026-07-12T12:00:00Z",
        "organization_id": organization_id,
        "resource_id": build_id,
        "correlation_id": str(uuid4()),
        "idempotency_key": f"build:{build_id}:requested",
        "producer": "control-plane",
        "schema_version": 1,
        "data": {
            "contract_version": 1,
            "command_type": "build.start",
            "operation_id": str(uuid4()),
            "organization_id": organization_id,
            "deployment_id": str(uuid4()),
            "build_id": build_id,
            "revision_id": str(uuid4()),
            "service_id": service_id,
            "expected_version": 3,
            "workload_type": "web",
            "repository": f"lrail/{organization_id}/{service_id}",
            "source_commit": COMMIT,
            "source_root": ".",
            "descriptor_digest": "sha256:" + "b" * 64,
        },
    }


class FakeControlPlane:
    def __init__(self, commands: list[dict[str, object]]):
        self.commands = commands
        self.finalized: list[dict[str, object]] = []
        self.events: list[dict[str, object]] = []
        self.cancellations: list[dict[str, object]] = []

    async def close(self):
        return None

    async def claim(self):
        if not self.commands:
            return None
        value = self.commands.pop(0)
        return CommandLease(event=value, claim_token=str(uuid4()))

    async def finalize(self, **value):
        self.finalized.append(value)
        return {"status": value["outcome"]}

    async def credentials(self, operation):
        return CloneCredentials(
            build_id=operation.build_id,
            clone_url="https://git.example.test/layerrail/sample.git",
            username="x-access-token",
            secret="ephemeral-clone-secret",
            expires_at="2099-07-12T12:15:00Z",
        )

    async def send_build_event(self, operation, **value):
        self.events.append({"operation": operation, **value})
        return {"result": {"ignored": False}}

    async def complete_cancellation(self, operation, **value):
        self.cancellations.append({"operation": operation, **value})
        return {"deployment_status": "canceled"}


class FakeRegistry:
    def __init__(self):
        self.credentials: list[RegistryCredential] = []
        self.revoked: list[str] = []

    async def close(self):
        return None

    async def register(self, *, repository, actions, expires_at):
        credential = RegistryCredential(
            credential_id=str(uuid4()),
            username="lr_registry_user",
            password="ephemeral-registry-secret",
            repository=repository,
            expires_at=expires_at,
        )
        self.credentials.append(credential)
        return credential

    async def revoke(self, credential_id):
        self.revoked.append(credential_id)


class FakeArtifacts:
    def __init__(self):
        self.values: list[tuple[str, bytes]] = []

    async def close(self):
        return None

    async def evidence(self, *, name, body, **_values):
        self.values.append((name, body))
        return {"name": name, "digest": "sha256:" + "e" * 64, "size": len(body)}

    async def static(self, **_values):
        return {"archive": {"digest": "sha256:" + "d" * 64}}


class FakeJobs:
    def __init__(self):
        self.dispatched: list[dict[str, object]] = []
        self.deleted: list[tuple[str, str]] = []
        self.states: dict[str, JobState] = {}

    async def start(self):
        return None

    async def close(self):
        return None

    async def dispatch(self, command, **values):
        self.dispatched.append({"command": command, **values})
        self.states[command.job_name] = JobState(True, True, False, False, None)
        return True

    async def status(self, job_name):
        return self.states.get(job_name, JobState(False, False, False, False, None))

    async def logs(self, _job_name):
        return ""

    async def delete(self, job_name, secret_name):
        self.deleted.append((job_name, secret_name))
        self.states.pop(job_name, None)


class FailingJobs(FakeJobs):
    async def dispatch(self, command, **values):
        del command, values
        raise RuntimeError("unexpected dispatch failure")


class FakeScanner:
    def __init__(self, *, passed=True):
        self.passed = passed

    async def scan_image(self, _reference, _credential):
        return ScanResult(
            sbom={"bomFormat": "CycloneDX"},
            report={"Results": []},
            summary={"critical": 0 if self.passed else 1, "high": 0, "medium": 0, "low": 0, "unknown": 0},
            passed=self.passed,
        )

    async def scan_static(self, _archive):
        return await self.scan_image("static", None)


class FakeProvenance:
    def sign(self, operation, **values):
        return {
            "statement": {"build_id": operation.build_id, **values},
            "signature": {"algorithm": "Ed25519", "value": "signed"},
        }


def settings(root: Path) -> Settings:
    secret = root / "shared-secret"
    secret.write_bytes(b"controller-shared-secret-at-least-32-bytes")
    placeholder = root / "placeholder"
    placeholder.write_bytes(b"placeholder-secret-at-least-32-bytes")
    return Settings(
        state_dir=root / "state",
        shared_secret_path=secret,
        registry_admin_secret_path=placeholder,
        artifact_admin_secret_path=placeholder,
        signing_key_path=placeholder,
        control_plane_url="http://control-plane:3000",
        control_plane_host="control.localhost",
        registry_auth_url="http://registry-auth:8080",
        registry_service="lrail-alpha-registry",
        registry_endpoint="registry:5000",
        artifact_gateway_url="http://artifact-gateway:8080",
        namespace="lrail-builds",
        worker_image="lrail-build-worker:dev",
        trivy_path=root / "trivy",
        port=8080,
        reconcile_interval=0.1,
        build_timeout_seconds=900,
        result_grace_seconds=5,
        max_result_bytes=48_000_000,
        max_static_archive_bytes=1 << 20,
        max_log_lines=1000,
        max_critical_vulnerabilities=0,
    )


class ControllerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = settings(root)
        self.event = envelope()
        self.command = BuildCommand.parse(self.event)
        self.control = FakeControlPlane([self.event])
        self.registry = FakeRegistry()
        self.artifacts = FakeArtifacts()
        self.jobs = FakeJobs()
        self.store = OperationStore(self.settings.state_dir)
        self.controller = BuildController(
            self.settings,
            store=self.store,
            control_plane=self.control,
            registry=self.registry,
            artifacts=self.artifacts,
            jobs=self.jobs,
            scanner=FakeScanner(),
            provenance=FakeProvenance(),
            authenticator=RequestAuthenticator(self.settings.shared_secret_path),
        )

    async def asyncTearDown(self):
        await self.controller.close()
        self.directory.cleanup()

    async def test_command_dispatch_and_completion_are_idempotent_and_sanitized(self):
        self.assertTrue(await self.controller.run_command_once())
        operation = self.store.get(self.command.build_id)
        self.assertEqual(operation.status, "running")
        self.assertEqual(len(self.jobs.dispatched), 1)
        self.assertEqual(self.control.finalized[0]["outcome"], "published")
        self.assertNotIn("ephemeral-clone-secret", repr(operation))

        result = WorkerResult.parse(
            {
                "contract_version": 1,
                "operation_id": self.command.operation_id,
                "build_id": self.command.build_id,
                "source_commit": COMMIT,
                "status": "completed",
                "plan_type": "dockerfile_web",
                "artifact_kind": "oci",
                "artifact_digest": "sha256:" + "c" * 64,
                "image_reference": f"registry:5000/{self.command.repository}@sha256:{'c' * 64}",
                "log_lines": [
                    "2026-07-12T12:00:00Z clone token=must-redact",
                    "2026-07-12T12:00:01Z build complete",
                ],
            },
            build_id=self.command.build_id,
            max_static_archive_bytes=1 << 20,
            max_log_lines=1000,
        )
        _operation, created = await self.controller.accept_result(result)
        self.assertTrue(created)
        await self.controller.reconcile_once()

        completed = self.store.get(self.command.build_id)
        self.assertEqual(completed.status, "completed")
        self.assertEqual(self.control.events[0]["status"], "completed")
        evidence = self.control.events[0]["evidence"]
        self.assertEqual(evidence["scan_status"], "passed")
        self.assertNotIn("must-redact", json.dumps(evidence))
        self.assertIn(self.registry.credentials[0].credential_id, self.registry.revoked)
        self.assertTrue(self.jobs.deleted)
        self.assertEqual(
            {name for name, _body in self.artifacts.values},
            {"build.log", "sbom.json", "scan.json", "provenance.json"},
        )

    async def test_critical_scan_failure_never_reports_completion(self):
        self.controller.scanner = FakeScanner(passed=False)
        await self.controller.run_command_once()
        result = WorkerResult.parse(
            {
                "contract_version": 1,
                "operation_id": self.command.operation_id,
                "build_id": self.command.build_id,
                "source_commit": COMMIT,
                "status": "completed",
                "plan_type": "dockerfile_web",
                "artifact_kind": "oci",
                "artifact_digest": "sha256:" + "d" * 64,
                "image_reference": f"registry:5000/{self.command.repository}@sha256:{'d' * 64}",
                "log_lines": [],
            },
            build_id=self.command.build_id,
            max_static_archive_bytes=1 << 20,
            max_log_lines=1000,
        )
        await self.controller.accept_result(result)
        await self.controller.reconcile_once()

        self.assertEqual(self.store.get(self.command.build_id).status, "failed")
        self.assertEqual(self.control.events[0]["status"], "failed")
        self.assertEqual(
            self.control.events[0]["failure"]["code"], "critical_vulnerability"
        )

    async def test_result_cannot_redirect_registry_credentials_to_another_host(self):
        await self.controller.run_command_once()
        result = WorkerResult.parse(
            {
                "contract_version": 1,
                "operation_id": self.command.operation_id,
                "build_id": self.command.build_id,
                "source_commit": COMMIT,
                "status": "completed",
                "plan_type": "dockerfile_web",
                "artifact_kind": "oci",
                "artifact_digest": "sha256:" + "f" * 64,
                "image_reference": f"attacker.example/{self.command.repository}@sha256:{'f' * 64}",
                "log_lines": [],
            },
            build_id=self.command.build_id,
            max_static_archive_bytes=1 << 20,
            max_log_lines=1000,
        )

        with self.assertRaisesRegex(OperationConflict, "artifact repository"):
            await self.controller.accept_result(result)

    async def test_result_grace_starts_when_job_completion_is_first_observed(self):
        await self.controller.run_command_once()
        operation = self.store.get(self.command.build_id)
        self.jobs.states[operation.job_name] = JobState(
            True, False, True, False, None
        )
        first_observation = operation.updated_at + 600

        with patch("build_controller.controller.time.time", return_value=first_observation):
            await self.controller.reconcile_once()

        observed = self.store.get(self.command.build_id)
        self.assertEqual(observed.status, "running")
        self.assertEqual(observed.completion_observed_at, first_observation)
        self.assertEqual(self.control.events, [])

        after_grace = first_observation + self.settings.result_grace_seconds + 1
        with patch("build_controller.controller.time.time", return_value=after_grace):
            await self.controller.reconcile_once()

        self.assertEqual(self.store.get(self.command.build_id).status, "failed")
        self.assertEqual(self.control.events[0]["failure"]["code"], "result_missing")

    async def test_unexpected_dispatch_failure_retries_without_leaking_credentials(self):
        self.controller.jobs = FailingJobs()

        self.assertTrue(await self.controller.run_command_once())

        self.assertEqual(self.control.finalized[0]["outcome"], "retry")
        self.assertEqual(
            self.control.finalized[0]["safe_error"],
            "build_controller_internal_error",
        )
        self.assertEqual(
            self.registry.revoked,
            [self.registry.credentials[0].credential_id],
        )


if __name__ == "__main__":
    unittest.main()
